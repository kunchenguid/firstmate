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
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-validation" / "cell.json"
GUEST = ROOT / "bin" / "fm-azure-validation-guest.sh"
SHARD_BRIDGE = ROOT / "bin" / "fm-azure-validation-shard-bridge.py"
CREDENTIAL_EXPIRY = ROOT / "bin" / "fm-credential-expiry.py"
CONTAINER = "validation-shards"
SCHEMA = "fm.azure-validation/v1"
RESULT_SCHEMA = "fm.azure-validation-result/v1"
CREDENTIALS_SCHEMA = "fm.azure-validation-credentials/v1"
RUNTIME_SCHEMA = "fm.azure-validation-runtime/v1"
# Byte-identical to CELL_HOST_CAPABILITY_DECLARATION in
# bin/fm-azure-validation-shard-bridge.py. This side is the refusal: a behavior
# shard command that does not carry exactly this declaration is not the sealed
# planner route, so the cell cannot quietly widen or drop the skip set.
CELL_HOST_CAPABILITY_DECLARATION = (
    "FM_TEST_HOST_CAPABILITIES_ABSENT="
    "real-tmux-server,passwordless-root-escalation,system-openat-binding,origin-egress"
)
# Azure firstmate is powered entirely by pi-codex; the single claude profile
# exists only for the cross-check lane. Add further providers here only when
# a lane actually consumes them.
PROVIDERS = ("codex", "claude")
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
SAFE_CELL = re.compile(r"^azv-[a-z0-9]{12}$")
HEX_OBJECT = re.compile(r"^[0-9a-f]{40,64}$")
SHA256 = re.compile(r"^sha256:[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")
PR_URL = re.compile(r"^https://github\.com/[^/]+/[^/]+/pull/[1-9][0-9]*$")
NM_RUN_ID = re.compile(r"^[0-9A-HJKMNP-TV-Z]{26}$")
RUNNER_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a[2-9][0-9]*)?$")
# The authenticated result marker. `attempt` is required: every other field
# a control-plane read can see is identical across the attempts of one run
# (same VM, same boot, same run id), so without it an unbound view cannot be
# told from this attempt's own answer.
MARKER = re.compile(
    r"FM_AZURE_VALIDATION_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})"
    r"\s+outcome=([a-z-]+)\s+attempt=([0-9]{1,18})"
)
# The pre-attempt marker shape. A guest sealed into a cell BEFORE the attempt
# stamp existed cannot be changed (the request is digest-sealed), so its output
# must stay readable or every cell in flight across that upgrade is stranded.
# Only consulted when the output carries no stamped marker at all: MARKER's
# prefix is exactly this shape, so a stamped marker would match it too.
LEGACY_MARKER = re.compile(
    r"FM_AZURE_VALIDATION_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})"
    r"\s+outcome=([a-z-]+)"
)
# Whether a guest CAN name its attempt is a property of the guest, read from the
# sealed bytes that actually run. It must never be inferred from whether a
# marker parsed: LEGACY_MARKER is MARKER minus the attempt group, so ANY
# malformation of the attempt field satisfies "no stamped marker matched".
GUEST_STAMPS_ATTEMPT = re.compile(r"^[^\n]*FM_AZURE_VALIDATION_RESULT[^\n]*attempt=", re.MULTILINE)
MARKER_SETTLE_SECONDS = 300
# Shard transports legitimately run VM creation plus admission plus command
# submission in one subprocess: near 300 seconds unloaded and well past it
# under any operator-host load. The old 300-second cap manufactured
# failed-retained shards whenever two transports ran concurrently
# (generations 044/046 ground truth); 900 still bounds a genuine hang.
LOCAL_TIMEOUT = 900
REGIONAL_ADMISSION_CEILING_VCPUS = 128
BUDGET_TARGET_USD = 1000.0
BUDGET_CEILING_USD = 1500.0
MAX_CELL_LIFETIME_HOURS = 24
FOUNDATION_METER_RESERVE_USD = 210.0
VALIDATION_METER_RESERVE_USD = 80.0
BLOB_DATA_CONTRIBUTOR_ROLE = "ba92f5b4-2d11-453d-a403-e96b0029c9fe"
# Storage File Data Privileged Contributor: the role OAuth FileREST access
# needs so the per-cell UAMI can sync the persistent fm-auth-home share.
FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE = "69566ab7-960f-475b-8e7c-b3118f30c6bd"

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

# Coordinator SKU spread: four concurrent coordinator cells cannot share one
# family cap, so lane index maps deterministically onto four reviewed
# eight-vCPU SKUs in four distinct families (Dasv6, Dsv6, Dadsv6, Ddsv6).
COORDINATOR_SKU_POOL = VALIDATION_SKUS

# Phases in which a cell occupies a dispatch lane (compute exists or is
# reserved). Queued, collected, closed, and retained-failure cells do not.
LANE_PHASES = (
    "starting", "running", "reattaching", "responding",
    "needs-decision", "result-published",
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


def marker_settle_seconds():
    """How long an unbound terminal control view may persist before it is believed."""
    raw = os.environ.get("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS")
    if raw is None or not raw.strip():
        return MARKER_SETTLE_SECONDS
    try:
        value = int(raw)
    except ValueError:
        raise ValidationError("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS must be a whole number of seconds")
    if value < 0:
        raise ValidationError("FM_AZURE_VALIDATION_MARKER_SETTLE_SECONDS must not be negative")
    return value


def seconds_since(stamp):
    """Elapsed seconds since an exact recorded UTC stamp, or None when unreadable.

    None is never treated as "long enough": an unreadable stamp keeps an
    ambiguous view unsettled rather than authorizing a terminal decision.
    """
    try:
        return (now_utc() - parse_utc(stamp, "recorded stamp")).total_seconds()
    except (ValidationError, TypeError):
        return None


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
        "lanes": bounded_int("FM_AZURE_VALIDATION_LANES", 4, 1, 8),
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


def all_states(env):
    ensure_dirs(env)
    states = []
    for path in env["state_dir"].glob("azv-*.json"):
        with contextlib.suppress(OSError, json.JSONDecodeError):
            value = json.loads(path.read_text(encoding="utf-8"))
            if value.get("schema") == SCHEMA and value.get("cell"):
                states.append(value)
    return states


def occupied_states(env, exclude_cell=None):
    return [
        state for state in all_states(env)
        if state.get("phase") in LANE_PHASES and state.get("cell") != exclude_cell
    ]


def lane_sku(lane):
    """Deterministic lane-index to coordinator-SKU mapping (family spread)."""
    return COORDINATOR_SKU_POOL[lane % len(COORDINATOR_SKU_POOL)]


def next_free_lane(used_lanes, lane_count):
    for index in range(lane_count):
        if index not in used_lanes:
            return index
    raise ValidationError("no validation lane is free")


def load_credentials(path):
    """Read the plain single-operator credentials descriptor.

    The descriptor names the provider plus host paths for a home-shaped auth
    directory (containing .codex/, .claude/, ... as they would sit in the
    agent user's home) and the GitHub token file. It carries no secret values
    itself; the auth directory ships to the cell inside the input archive as
    the first-boot seed (the fm-auth-home share overlays it afterwards) and
    the token flows at dispatch time as a run-command parameter.
    """
    source = Path(path).expanduser().resolve()
    try:
        value = json.loads(source.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValidationError("credentials descriptor is unreadable: {}".format(exc))
    if not isinstance(value, dict) or value.get("schema") != CREDENTIALS_SCHEMA:
        raise ValidationError("credentials descriptor schema is invalid")
    provider = value.get("provider")
    if provider not in PROVIDERS:
        raise ValidationError("credentials provider is not a verified Firstmate adapter")
    auth_home = Path(str(value.get("auth_home", ""))).expanduser()
    if not str(value.get("auth_home", "")) or not auth_home.is_dir():
        raise ValidationError("credentials auth_home must be an existing home-shaped directory")
    token_file = Path(str(value.get("github_token_file", ""))).expanduser()
    if not str(value.get("github_token_file", "")) or not token_file.is_file():
        raise ValidationError("credentials github_token_file must be an existing file")
    return {
        "provider": provider,
        "auth_home": auth_home,
        "github_token_file": token_file,
    }


def auth_share_name():
    """Configured persistent auth share; empty disables the auth-home sync."""
    return os.environ.get("FM_AZURE_AUTH_SHARE", "fm-auth-home")


def storage_account_scope(env):
    return "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}".format(
        env["subscription"], env["resource_group"], env["storage"]
    )


def read_github_token(state):
    """Read the current GitHub token for boot-time injection into the guest."""
    override = os.environ.get("FM_AZURE_GITHUB_TOKEN_FILE")
    path = Path(override) if override else Path(state["request"]["credentials"]["github_token_file"])
    try:
        token = path.expanduser().read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise ValidationError("GitHub token file is unreadable: {}".format(exc))
    if not token:
        raise ValidationError("GitHub token file is empty")
    return token


def pack_auth_home(auth_home, destination):
    with tarfile.open(destination, "w:gz", format=tarfile.PAX_FORMAT) as archive:
        for source in sorted(auth_home.rglob("*")):
            if source.is_symlink():
                continue
            arcname = source.relative_to(auth_home).as_posix()
            info = archive.gettarinfo(str(source), arcname=arcname)
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = 0
            if source.is_file():
                with open(source, "rb") as handle:
                    archive.addfile(info, handle)
            elif source.is_dir():
                archive.addfile(info)
    if destination.stat().st_size > 1024**3:
        raise ValidationError("auth home bundle exceeds one GiB")


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


def prepare_payload(env, state, runtime_source, auth_home):
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
    credentials_copy = payload / "credentials.tar.gz"
    pack_auth_home(auth_home, credentials_copy)
    state["request"]["credentials"]["bundle_digest"] = sha256_file(credentials_copy)
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
        (credentials_copy, "credentials.tar.gz"),
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
        credentials = load_credentials(args.credential_lease)
        runtime, runtime_digest = validate_runtime_bundle(args.runtime_bundle, credentials["provider"])
        cell = new_cell()
        token = cell.split("-", 1)[1]
        resources = resource_names(env, token)
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
            "credentials": {
                "provider": credentials["provider"],
                "github_token_file": str(credentials["github_token_file"]),
                "bundle_digest": None,
            },
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
                "lineage_prefix": staging_prefix,
            },
            "resources": resources,
            "events": [{"at": iso_utc(), "phase": "preparing", "note": "queue identity reserved"}],
        }
        ensure_dirs(env)
        save_state(env, state, create=True)
        try:
            prepare_payload(
                env, state, Path(args.runtime_bundle).resolve(),
                credentials["auth_home"],
            )
            transition(env, state, "queued", "exact pushed head queued without local validation execution")
        except Exception:
            with contextlib.suppress(OSError):
                state_path(env, cell).unlink()
            shutil.rmtree(env["state_dir"] / "payloads" / cell, ignore_errors=True)
            raise
    print("AZURE VALIDATION QUEUED cell={} task={} head={} class={} shards={}".format(
        cell, task, head, resource_class, limits["behavior_shards"]
    ))


def resource_names(env, token):
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


_CREDENTIAL_EXPIRY_MODULE = None


def credential_expiry_module():
    global _CREDENTIAL_EXPIRY_MODULE
    if _CREDENTIAL_EXPIRY_MODULE is None:
        spec = importlib.util.spec_from_file_location(
            "credential_expiry_module", str(CREDENTIAL_EXPIRY)
        )
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        _CREDENTIAL_EXPIRY_MODULE = module
    return _CREDENTIAL_EXPIRY_MODULE


# What the fm-auth-home share actually is, verified against both consumers:
# the guest's auth_home_pull copies the WHOLE share into one cell home and the
# guest exports CODEX_HOME=$HOME/.codex or CLAUDE_CONFIG_DIR=$HOME/.claude, so
# the share is exactly one home-shaped tree holding at most one codex profile
# and one claude profile. Crosscheck reviewers never read the share at all;
# they receive a per-review credential archive. There is therefore no consumer
# for a multi-profile layout, and inventing one would write bytes nothing
# reads. Seeding keeps the layout the consumers already expect.
#
# Only the credential file itself is uploaded. Sessions, history, caches, and
# project state are cell-local by design and have no reason to sit on a shared
# Azure Files share.
AUTH_HOME_LAYOUT = {
    "codex": (".codex", "auth.json"),
    "claude": (".claude", ".credentials.json"),
}


def auth_seed_targets(args):
    """Resolve the requested harness/profile pairs for one seeding run."""

    selected = []
    for harness in PROVIDERS:
        value = getattr(args, harness, None)
        if not value:
            continue
        profile = Path(value).expanduser()
        if not profile.is_dir() or profile.is_symlink():
            raise ValidationError(
                "{} profile must be an existing non-symlink directory: {}".format(
                    harness, profile
                )
            )
        directory, credential = AUTH_HOME_LAYOUT[harness]
        source = profile.resolve() / credential
        if not source.is_file() or source.is_symlink():
            raise ValidationError(
                "{} profile holds no regular {} to seed: {}".format(
                    harness, credential, source
                )
            )
        selected.append({
            "harness": harness,
            "profile": profile.resolve(),
            "source": source,
            "share_directory": directory,
            "share_path": "{}/{}".format(directory, credential),
        })
    if not selected:
        raise ValidationError(
            "auth-seed requires at least one of --codex or --claude"
        )
    return selected


def auth_seed_preflight(targets):
    """Refuse to publish a credential the cells cannot authenticate with.

    Seeding exists to carry a freshly re-authenticated profile onto the share.
    A profile whose access token is already dead would be uploaded, pulled by
    every later boot, and fail there instead of here, so it is refused with
    its own expiry named.
    """

    expiry = credential_expiry_module()
    for target in targets:
        record = expiry.inspect_profile(
            target["profile"], harness=target["harness"]
        )
        try:
            expiry.require_state(record, "usable", "fm-auth-home seed")
        except expiry.CredentialExpiryError as exc:
            raise ValidationError(
                "{}; re-authenticate that profile and seed again".format(exc)
            )
        target["expiry"] = record
    return targets


def auth_seed(env, args):
    """Publish selected local credentials onto the persistent auth share.

    Plan is local and touches no Azure. Apply requires the exact subscription
    plus an explicit seed confirmation, uploads each credential to the exact
    path its consumer reads, and then re-reads the share to prove the upload.
    """

    targets = auth_seed_preflight(auth_seed_targets(args))
    share = auth_share_name()
    if not share:
        raise ValidationError("FM_AZURE_AUTH_SHARE is empty; the auth-home sync is disabled")
    if not args.apply:
        print("auth-seed plan (no Azure call made)")
        print("  share: {}".format(share))
        for target in targets:
            print("  {} {} -> {}".format(
                target["harness"], target["source"], target["share_path"]
            ))
            print("    state {} expires {}".format(
                target["expiry"]["state"], target["expiry"]["expires_at"]
            ))
        print("  apply with: --apply --confirm-seed --confirm-subscription <exact-id>")
        return
    if not args.confirm_seed:
        raise ValidationError("auth-seed --apply requires --confirm-seed")
    if args.confirm_subscription != env["subscription"]:
        raise ValidationError("auth-seed --apply requires the exact --confirm-subscription")
    scope_gate(env)
    backup = ["--auth-mode", "login", "--enable-file-backup-request-intent"]
    for target in targets:
        az_command(env, [
            "storage", "directory", "create",
            "--account-name", env["storage"],
            "--share-name", share,
            "--name", target["share_directory"],
        ] + backup)
        _, code, detail = az_command(env, [
            "storage", "file", "upload",
            "--account-name", env["storage"],
            "--share-name", share,
            "--source", str(target["source"]),
            "--path", target["share_path"],
        ] + backup, check=False)
        if code != 0:
            raise ValidationError("auth-seed upload failed for {}: {}".format(
                target["share_path"], detail
            ))
        # An accepted upload is not proof: re-read the share and require the
        # exact byte count, so a truncated or replaced object is caught here
        # instead of at the next cell boot.
        published, code, detail = az_command(env, [
            "storage", "file", "show",
            "--account-name", env["storage"],
            "--share-name", share,
            "--path", target["share_path"],
        ] + backup, check=False)
        expected = target["source"].stat().st_size
        published_size = ((published or {}).get("properties") or {}).get("contentLength")
        if code != 0 or published_size != expected:
            raise ValidationError(
                "auth-seed could not prove {} landed at its expected {} bytes: {}".format(
                    target["share_path"], expected, detail or published_size
                )
            )
        print("auth-seed published {} ({} bytes, expires {})".format(
            target["share_path"], expected, target["expiry"]["expires_at"]
        ))


def lifecycle_command(env, arguments):
    command_env = os.environ.copy()
    # The allocator store is fenced to its home identity, so the operator's
    # exported FM_HOME must win when the CLI runs from a different checkout;
    # the script root is only the fallback when no home is declared.
    command_env.setdefault("FM_HOME", str(ROOT))
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
    shard_limits = dict(runner.RESOURCE_CLASSES["behavior-heavy"])
    for shard in range(1, int(shards) + 1):
        sku = shard_skus[(shard - 1) % len(shard_skus)]
        # The constituent must cover the child runner's own parent-managed
        # first-day itemized bound, or its idempotent re-admission can never
        # fit the cushion; the exact same bound model produces the amount.
        limits = dict(shard_limits, sku=sku, sku_family=runner.SKU_FAMILY[sku])
        bound = runner.itemized_cost_bound(
            float(rate_lookup(sku)), runner.MAX_BILLABLE_LIFETIME_HOURS,
            limits, parent_managed=True,
        )
        plan.append({
            "shard": shard,
            "invocation": "azr-" + uuid.uuid4().hex[:12],
            "sku": sku,
            "sku_family": runner.SKU_FAMILY[sku],
            "amount_usd": round(bound["total"] + 1.0, 6),
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
        detail = (result.stderr or result.stdout or "").strip()
        # Release is a cleanup operation and must be idempotent: a
        # constituent already released under another recorded receipt (an
        # operator supersede raced a queued dispatch in generation 054)
        # leaves nothing reserved, so the released end state satisfies
        # this release instead of wedging close into cleanup-retained.
        # Both receipts remain in the durable ledger.
        if "already has a different cleanup receipt" in detail:
            return
        raise ValidationError("shared capacity release refused for {}: {}".format(
            reservation_id, detail[-400:]
        ))


RETAIL_RATE_CACHE_FRESH_SECONDS = 7 * 24 * 3600


def retail_rate(env, sku):
    """Resolve the SKU's hourly retail rate through a durable cache.

    Dispatch prices the cell plus the whole shard SKU pool in one burst, and
    prices.azure.com throttles bursts hard (generation 045 lost 21 minutes to
    HTTP 429 backoff before a single VM existed). The rate only feeds
    worst-case cost ceilings, so a same-week cached value bounds spend just as
    well: fresh cache entries skip the API, stale entries are refreshed
    best-effort and used verbatim when the API throttles, and only a SKU with
    no cached rate at all requires the live read to succeed.
    """
    # An environment without durable state (the transport contract drives
    # this function with a bare env) prices directly with no cache.
    state_dir = env.get("state_dir")
    if state_dir is None:
        return retail_rate_from_api(env, sku)
    cache_path = state_dir / "retail-rate-cache.json"
    try:
        cache = json.loads(cache_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        cache = {}
    entry = cache.get(sku)
    now = time.time()
    if (
        isinstance(entry, dict)
        and isinstance(entry.get("rate"), (int, float))
        and entry["rate"] > 0
        and isinstance(entry.get("fetched_at"), (int, float))
        and now - entry["fetched_at"] < RETAIL_RATE_CACHE_FRESH_SECONDS
    ):
        return float(entry["rate"])
    try:
        rate = retail_rate_from_api(env, sku)
    except ValidationError as exc:
        if isinstance(entry, dict) and isinstance(entry.get("rate"), (int, float)) and entry["rate"] > 0:
            print(
                "azure-validation: retail rate API unavailable ({}); using cached ceiling for {}".format(
                    str(exc)[:120], sku
                ),
                file=sys.stderr,
            )
            return float(entry["rate"])
        raise
    cache[sku] = {"rate": rate, "fetched_at": now}
    tmp = cache_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(cache_path)
    return rate


def retail_rate_from_api(env, sku):
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
        identity["etag"] = identity["etag"] or identity["unique_id"]
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
        or (kind not in ("identity", "run-command", "ttl-schedule") and not identity["etag"])
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
    zone = os.environ.get("FM_AZURE_VALIDATION_ZONE", "1")
    if zone not in ("1", "2", "3"):
        raise ValidationError("FM_AZURE_VALIDATION_ZONE must be 1, 2, or 3")
    return {
        "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#",
        "contentVersion": "1.0.0.0",
        "parameters": {
            "region": {"value": "eastus"},
            "zone": {"value": zone},
            "vmName": {"value": resources["vm_name"]},
            "nicName": {"value": resources["nic_name"]},
            "osDiskName": {"value": resources["os_disk_name"]},
            "worktreeDiskName": {"value": resources["worktree_disk_name"]},
            "worktreeDiskId": {"value": resources["worktree_disk_id"]},
            "createWorktreeDisk": {"value": not replacement},
            "authShareName": {"value": auth_share_name()},
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
            # Optional golden image: an empty value keeps the marketplace
            # base; the guests re-verify every staged archive digest at
            # boot either way, so the image only caches the bootstrap.
            "imageId": {"value": os.environ.get("FM_AZURE_VM_IMAGE_ID", "")},
        },
    }


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
    blob_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], BLOB_DATA_CONTRIBUTOR_ROLE
    )
    file_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
    )
    expected_grants = {(container_scope.lower(), blob_role.lower())}
    if auth_share_name():
        # The deployment grants the cell identity file-data access for the
        # persistent auth share alongside its private-container blob grant.
        expected_grants.add((storage_account_scope(env).lower(), file_role.lower()))
    if (
        not isinstance(assignments, list)
        or any(
            str(item.get("principalId", "")).lower() != str(principal_id).lower()
            for item in assignments
        )
        or {
            (str(item.get("scope", "")).lower(), str(item.get("roleDefinitionId", "")).lower())
            for item in assignments
        } != expected_grants
    ):
        raise ValidationError("cell identity effective RBAC exceeds its exact container and auth-share grants")
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


def sealed_guest_text(env, state):
    """The exact guest text this cell's request was sealed with.

    The seal binds the guest a cell was ADMITTED with. Reading the working tree
    instead made that seal depend on the tree never changing, so ANY later edit
    to the guest refused `respond`, `reattach` AND `replace` on every cell
    already in flight, stranding them with no recovery (`replace` is the only
    documented way out of `failed-retained`, and it routes through here too).
    `submit` stages a byte copy of the guest beside the request, so that copy is
    the sealed artifact and is what a resumed attempt must run. The working tree
    is used only when it still matches the seal, which keeps a cell whose
    payload was pruned behaving exactly as before. Neither source is trusted on
    provenance: the bytes are read ONCE, digested in memory, and those exact
    bytes are what is returned, so what executes on the cell is what was
    verified rather than whatever a later read would have found. This widens
    recovery without widening what may execute.
    """
    expected = state["request"]["protocol"]["guest_digest"]
    candidates = []
    state_dir = env.get("state_dir")
    if state_dir:
        candidates.append(Path(state_dir) / "payloads" / state["cell"] / "guest.sh")
    candidates.append(GUEST)
    for candidate in candidates:
        try:
            if not candidate.is_file() or candidate.is_symlink():
                continue
        except OSError:
            continue
        # ONE read. Digesting the file and then re-reading it to return would
        # verify bytes that are not the bytes returned: a writer landing between
        # the two reads passes the check and ships different content, and that
        # content is uploaded as the Run Command script and executes as root on
        # the cell. Digest exactly the bytes that are handed back.
        try:
            data = candidate.read_bytes()
        except OSError:
            continue
        if "sha256:" + hashlib.sha256(data).hexdigest() == expected:
            try:
                return data.decode("utf-8")
            except UnicodeDecodeError:
                continue
    raise ValidationError(
        "no guest matching this cell's exact sealed request digest is available; "
        "neither the staged payload copy nor the working tree carries {}".format(expected)
    )


def guest_text_stamps_attempt(text):
    """Does this exact guest text emit an attempt-stamped result marker?"""
    return bool(GUEST_STAMPS_ATTEMPT.search(text))


def guest_stamps_attempt(env, state):
    """Whether this cell's SEALED guest can name the attempt in its marker.

    Read from the guest, never inferred from the output. Inferring it from "no
    stamped marker matched" hands the weaker pre-stamp contract to any cell
    whose marker is merely MALFORMED, and the marker is the guest's last line by
    design, which is exactly where an output cap lands. The consequence is not
    theoretical: a stale attempt-1 marker truncated inside its own attempt field
    makes the stamped set empty, binds legacy, sets the expected digest to
    attempt 1's own, matches the blob that still holds attempt 1's archive, and
    skips the attempt check - accepting attempt 1's result as attempt 2's
    answer, which is the exact silent false verdict this binding exists to
    prevent. Recorded at create time where the sealed text is already in hand,
    and derived from the sealed guest for a cell whose state predates that.
    An underivable answer takes the STRICT contract, never the weaker one.
    """
    recorded = state.get("guest_stamps_attempt")
    if isinstance(recorded, bool):
        return recorded
    try:
        return guest_text_stamps_attempt(sealed_guest_text(env, state))
    except (ValidationError, KeyError, TypeError, OSError):
        # A state that cannot answer the question at all - no seal recorded, no
        # staged payload, a truncated request - is not evidence that the guest
        # cannot stamp. Take the STRICT contract: the worst case is a cell that
        # must be observed again, never one that accepts another attempt's
        # result as this attempt's answer.
        return True


def create_run_command(env, state, mode, input_url=None, output_url=None, response=None):
    resources = state["resources"]
    guest_text = sealed_guest_text(env, state)
    # Recorded from the bytes that are about to run, so observe never has to
    # guess it from output that may be truncated.
    state["guest_stamps_attempt"] = guest_text_stamps_attempt(guest_text)
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
        {"name": "storage_account", "value": env["storage"]},
        {"name": "storage_container", "value": state["staging"]["container"]},
        {"name": "identity_client_id", "value": resources["identity_client_id"]},
        {"name": "auth_share", "value": auth_share_name()},
    ]
    protected = []
    if input_url:
        protected.append({"name": "input_url", "value": input_url})
    if output_url:
        protected.append({"name": "output_url", "value": output_url})
    if response is not None:
        protected.append({"name": "response", "value": response})
    # Boot-time credential injection: the token reaches the guest as a
    # run-command parameter and never lands in durable state files.
    protected.append({"name": "github_token", "value": read_github_token(state)})
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
            "source": {"script": guest_text},
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
    # Every attempt starts its own settling window: a stamp left by the
    # previous attempt's unbound view must never shorten this one's.
    state.pop("unbound_view_since", None)
    resources.setdefault("run_commands", []).append({
        "id": run_id,
        "identity": immutable_identity(run_command, "run-command"),
    })
    save_state(env, state)


def dispatch_cell(env, state, lane):
    """Admit one queued/starting cell into its lane; returns started or queued."""
    if state["request"]["deployment_generation"] != env["deployment_generation"]:
        raise ValidationError("queued request deployment generation differs from the live foundation")
    live_resources = resource_names(env, state["cell"].split("-", 1)[1])
    expected_bindings = state["request"].get("resource_bindings") or {}
    actual_bindings = {
        "vm_id": live_resources["vm_id"],
        "worktree_disk_id": live_resources["worktree_disk_id"],
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
        state["lane"] = lane
        save_state(env, state)
    if recovering:
        lane = state.get("lane", lane)
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
        candidates = sku_candidates(env, limits["vcpus"], limits["memory_gib"])
        # The lane's deterministic pool SKU keeps concurrent coordinator
        # cells in distinct families; a lane SKU that is not currently live
        # falls back to the cheapest live candidate.
        preferred = lane_sku(lane)
        selected = next((item for item in candidates if item["sku"] == preferred), candidates[0])
        selected["owner"] = env["owner"]
        shape = shared_shape_reserve(env, state, selected)
        if shape["status"] != "reserved":
            state.setdefault("admission", {})["shard_plan"] = shape["shard_plan"]
            state["admission"]["last_refusal"] = {"at": iso_utc(), "reason": shape.get("reason", "")[:400]}
            save_state(env, state)
            print("AZURE VALIDATION QUEUED cell={} reason={}".format(state["cell"], shape.get("reason", "")))
            return "queued"
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
    create_cell(env, state, selected)
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
    print("AZURE VALIDATION STARTED cell={} lane={} sku={} head={}".format(
        state["cell"], state.get("lane"), selected["sku"], state["request"]["repository"]["head"]
    ))
    return "started"


def dispatch(env, args):
    """Admit queued generations FIFO into free lanes, one cell per lane.

    Recovery of a starting cell comes first (it already owns its lane), then
    queued cells oldest-first while a lane is free. Strict FIFO: a shape the
    allocator queues stops admission so younger work never jumps the line.
    """
    if not args.confirm_dispatch or args.confirm_subscription != env["subscription"]:
        raise ValidationError("billable dispatch requires --confirm-dispatch and the exact subscription")
    with lock(env):
        candidates = [
            state for state in all_states(env)
            if state.get("phase") in ("queued", "starting")
        ]
        candidates.sort(key=lambda item: (
            0 if item.get("phase") == "starting" else 1,
            item.get("created_at", ""), item.get("cell", ""),
        ))
        if not candidates:
            print("AZURE VALIDATION QUEUE empty active={}".format(len(occupied_states(env))))
            return
        # A queued submission whose shape reservation has been released is
        # a superseded corpse, not a candidate: dispatching it runs a cell
        # outside its capacity accounting and every shard transport fails
        # on its released constituent (generation 054 ground truth, where
        # an operator supersede raced this FIFO). Skip released fences.
        controller_path = env["home"] / "state" / "azure-workers" / "controller.json"
        try:
            reservations = json.loads(controller_path.read_text(encoding="utf-8")).get("capacity_reservations", {})
        except (OSError, json.JSONDecodeError):
            reservations = {}
        live = []
        for item in candidates:
            entry = reservations.get(item.get("cell"))
            if entry is not None and entry.get("status") == "released":
                print("AZURE VALIDATION SKIPPED cell={} shape reservation already released".format(item.get("cell")))
                continue
            live.append(item)
        candidates = live
        if not candidates:
            print("AZURE VALIDATION QUEUE empty active={}".format(len(occupied_states(env))))
            return
        scope_gate(env)
        foundation_gate(env)
        started = 0
        for candidate in candidates:
            occupied = occupied_states(env, exclude_cell=candidate["cell"])
            if candidate["phase"] == "queued" and len(occupied) >= env["lanes"]:
                print("AZURE VALIDATION LANES FULL used={}/{} queued={}".format(
                    len(occupied), env["lanes"], count_queued(env)
                ))
                break
            used_lanes = {
                state.get("lane") for state in occupied
                if isinstance(state.get("lane"), int)
            }
            lane = (
                candidate.get("lane")
                if candidate["phase"] == "starting" and isinstance(candidate.get("lane"), int)
                else next_free_lane(used_lanes, env["lanes"])
            )
            outcome = dispatch_cell(env, candidate, lane)
            if outcome != "started":
                break
            started += 1
        print("AZURE VALIDATION DISPATCH started={} lanes_used={}/{} queued={}".format(
            started, len(occupied_states(env)), env["lanes"], count_queued(env)
        ))


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
        stamped = list(MARKER.finditer(output))
        # Accept ANY marker naming the attempt being observed, not merely the
        # first one in the output: re.search would hand back an earlier
        # attempt's line and retain an attempt that completed correctly.
        mine = {
            (found.group(1), found.group(2), found.group(3))
            for found in stamped
            if int(found.group(4)) == state["attempt"]
        }
        binding = "attempt"
        if len(mine) > 1:
            # Two different results claiming one attempt is not an answer.
            mine = set()
        if not mine and not stamped and not guest_stamps_attempt(env, state):
            # No stamped marker anywhere AND the sealed guest provably cannot
            # stamp. The second half is what keeps a malformed marker from
            # buying the weaker contract. Either nothing published, or the cell
            # runs a guest sealed BEFORE the stamp existed. That guest cannot be
            # changed, because the request is digest-sealed, so refusing to read
            # it would strand every cell in flight across this upgrade: the
            # attempt would be retained on a fully-published result and
            # `expected_result_digest` would never be set, making the result
            # unreachable. Fall back to the pre-stamp shape, which is consulted
            # ONLY here because MARKER's prefix is exactly that shape and would
            # otherwise match a stamped marker too. A stamped marker naming
            # another attempt never reaches this branch and still fails closed.
            legacy = LEGACY_MARKER.search(output)
            if legacy:
                mine = {(legacy.group(1), legacy.group(2), legacy.group(3))}
                binding = "legacy"
        if not mine:
            # A terminal control state whose output does not carry THIS
            # attempt's marker proves nothing about this attempt. The run
            # command, the VM, the boot, and every identity field in
            # result.json are shared across the attempts of one run, so an
            # unbound view is ambiguous between "the guest died before
            # publishing" and "the control plane has not caught up with the
            # attempt just created". Retaining on the first such read is
            # destructive and unrecoverable: failed-retained is a phase
            # observe itself refuses, so one premature poll strands a cell
            # whose attempt is still executing (generation azv-36b2 ground
            # truth: read nine seconds after the respond Run Command was
            # created). Fail closed by never ACCEPTING an unbound view, and
            # take the terminal decision only once the ambiguity persists.
            settle_seconds = marker_settle_seconds()
            since = state.get("unbound_view_since")
            if not since:
                state["unbound_view_since"] = iso_utc()
                save_state(env, state)
                since = state["unbound_view_since"]
            waited = seconds_since(since)
            if waited is None or waited < settle_seconds:
                observed = ",".join(sorted({found.group(4) for found in stamped})) or "none"
                print(
                    "AZURE VALIDATION UNSETTLED cell={} attempt={} control_state={} "
                    "marker_attempt={} waited={}s settle={}s".format(
                        state["cell"], state["attempt"], execution,
                        observed, "unknown" if waited is None else int(waited), settle_seconds,
                    )
                )
                return
            transition(env, state, "failed-retained", "cell ended without an authenticated result marker", control_error=error[-2000:])
            raise ValidationError("cell ended without an authenticated result; worktree and lease remain retained")
        state.pop("unbound_view_since", None)
        digest, boot_id, outcome = next(iter(mine))
        # How this observation was bound decides how strictly the collected
        # result is checked. A stamped marker means the guest can name its
        # attempt, so its result MUST; a legacy marker cannot, so it is held to
        # the pre-stamp contract instead of being refused.
        state["result_binding"] = binding
        # A republished byte-identical result is a non-answer, not a verdict.
        # An attempt that resumes a parked run without answering its gate, or
        # one whose upload never happened and left the previous attempt's
        # archive in place, publishes the exact bytes the previous attempt
        # did. Name that instead of surfacing a generic failure.
        previous = state.get("attempt_result_digests") or {}
        stale = sorted(
            key for key, value in previous.items()
            if value == digest and key != str(state["attempt"])
        )
        if stale:
            transition(
                env, state, "failed-retained",
                "attempt republished attempt {} result unchanged; the gate was not answered".format(
                    ", ".join(stale)
                ),
                control_error=error[-2000:],
            )
            raise ValidationError(
                "attempt {} published a byte-identical copy of attempt {}'s result; the operator "
                "response did not reach the in-cell pipeline, so this is a non-answer, not a "
                "verdict".format(state["attempt"], ", ".join(stale))
            )
        previous[str(state["attempt"])] = digest
        state["attempt_result_digests"] = previous
        state["expected_result_digest"] = digest
        state["expected_boot_id"] = boot_id
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
        "vm_resource_id": state["resources"]["vm_id"],
        "vm_instance_id": state["resources"]["vm_instance_id"],
        "boot_id": state.get("expected_boot_id"),
    }
    for key, wanted in expected.items():
        if result.get(key) != wanted:
            raise ValidationError("validation result identity mismatch: {}".format(key))
    # The attempt is the only field separating one attempt's result from
    # another's on a resumed run, so where the guest can name it, it is required
    # rather than defaulted: a result that does not declare its attempt is
    # refused, never assumed to be the current one. `result_binding` is set by
    # observe from the marker it actually read, so a cell whose sealed guest
    # predates the stamp is held to the pre-stamp contract instead of being
    # refused, and every cell that CAN prove its attempt still must.
    if state.get("result_binding", "attempt") != "legacy":
        if not isinstance(result.get("attempt"), int) or isinstance(result.get("attempt"), bool):
            raise ValidationError("validation result does not declare the attempt that produced it")
        if result["attempt"] != state["attempt"]:
            raise ValidationError(
                "validation result was produced by attempt {}, not the observed attempt {}".format(
                    result["attempt"], state["attempt"]
                )
            )
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
        receipt_heads = set()
        receipt_trees = set()
        # Receipts must be this cell's own shard round, not merely a
        # well-formed set at an ancestor head. The controller recorded every
        # shard it dispatched for this run in shard_runs (keyed by the shard
        # request digest, carrying the round, shard index, head, command, and
        # invocation it actually created), so an alien round smuggled onto the
        # durable disk cannot correspond and is refused here rather than
        # trusted on disk structure alone.
        dispatched = state.get("shard_runs") or {}
        for item in shard_receipts:
            if not isinstance(item, dict):
                raise ValidationError("behavior shard receipt is malformed")
            if (
                item.get("kind") != "behavior"
                or item.get("shard_count") != expected_shards
                or not HEX_OBJECT.match(str(item.get("head", "")))
                or not HEX_OBJECT.match(str(item.get("tree", "")))
                or not SHA256.match(str(item.get("request_digest", "")))
                or not SHA256.match(str(item.get("command_digest", "")))
                or not RUNNER_INVOCATION.match(str(item.get("invocation", "")))
                or not item.get("boot_id")
                or not item.get("vm_instance_id")
            ):
                raise ValidationError("behavior shard receipt identity is incomplete or stale")
            record = dispatched.get(str(item.get("request_digest")))
            if (
                not isinstance(record, dict)
                or record.get("round") != item.get("round")
                or record.get("shard") != item.get("shard")
                or record.get("head") != item.get("head")
                or record.get("command_digest") != item.get("command_digest")
                or record.get("invocation") != item.get("invocation")
            ):
                raise ValidationError("behavior shard receipts do not correspond to this cell's own dispatched shard round")
            receipt_heads.add(item["head"])
            receipt_trees.add(item["tree"])
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
            or len(receipt_heads) != 1
            or len(receipt_trees) != 1
        ):
            raise ValidationError("behavior shards did not prove one complete round on independent Azure machines")
        receipt_head = next(iter(receipt_heads))
        receipt_tree = next(iter(receipt_trees))
        if receipt_head != head:
            # The pipeline commits documentation on top of the tested tree
            # after the shard round, so the receipts legitimately prove an
            # exact ancestor of the published head rather than the head
            # itself. The ancestor and its tree binding are verified in the
            # controller clone against the fetched published branch; any
            # receipt head outside the published history still refuses.
            repo_root = Path(state["repository_root"])
            git(repo_root, "fetch", "origin", "refs/heads/" + str(result.get("branch", "")))
            probe = git(repo_root, "merge-base", "--is-ancestor", receipt_head, head, check=False)
            if probe.returncode != 0:
                raise ValidationError("behavior shard receipts do not prove an ancestor of the published head")
            if git(repo_root, "rev-parse", receipt_head + "^{tree}").stdout.strip() != receipt_tree:
                raise ValidationError("behavior shard receipt tree does not match its receipt head")
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


def replacement_allowed(state, vm_presence):
    """Minimum absence fence: VM gone plus a phase that owns recoverable work."""
    if vm_presence != "absent-proven":
        return False, "old VM absence is not proven"
    if state.get("phase") not in ("running", "needs-decision", "failed-retained", "responding", "reattaching"):
        return False, "cell phase does not own recoverable work"
    return True, "replacement admitted"


def replacement_run_mode(state):
    return "reattach" if state.get("run_id") is not None else "start"


def replace(env, args):
    if not args.confirm_replace or args.confirm_subscription != env["subscription"]:
        raise ValidationError("replacement requires --confirm-replace and the exact subscription")
    with lock(env, require_cell(args.cell)):
        state = load_state(env, args.cell)
        exists, _vm = read_resource(env, state["resources"]["vm_id"], "vm")
        if exists:
            raise ValidationError("old exact VM still exists; duplicate replacement is forbidden")
        work_exists, _worktree = read_resource(env, state["resources"]["worktree_disk_id"], "disk")
        if not work_exists:
            raise ValidationError("durable validation worktree disk is absent")
        allowed, reason = replacement_allowed(state, "absent-proven")
        if not allowed:
            raise ValidationError(reason)
        run_mode = replacement_run_mode(state)
        # Remove the old attempt's disposable remnants before their names
        # leave authoritative state. Durable worktree, identity, and private
        # container are retained.
        cleanup_compute(env, state)
        worktree_identity = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        state["attempt"] += 1
        token = state["cell"].split("-", 1)[1] + "a{}".format(state["attempt"])
        old_resources = state["resources"]
        old_worktree_id = old_resources["worktree_disk_id"]
        old_worktree_name = old_resources["worktree_disk_name"]
        state["resources"] = resource_names(env, token)
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
        if run_mode == "start":
            input_url = blob_sas(
                env, state["staging"]["input_blob"], "r",
                container=state["staging"]["container"],
            )
            create_run_command(env, state, "start", input_url=input_url, output_url=output_url)
            note = "replacement VM freshly starting because no no-mistakes run id was recorded"
        else:
            create_run_command(env, state, "reattach", output_url=output_url)
            note = "replacement VM reattaching to the exact retained durable worktree"
        transition(env, state, "running", note)
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
    arguments = [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(resource_id, RESOURCE_API[kind]),
    ]
    if identity["etag"]:
        arguments += ["--headers", "If-Match={}".format(identity["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
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
    arguments = [
        "rest", "--method", "delete",
        "--url", "https://management.azure.com{}?api-version={}".format(run_id, RESOURCE_API["run-command"]),
    ]
    if live["etag"]:
        arguments += ["--headers", "If-Match={}".format(live["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
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


def delete_auth_share_role(env, state):
    """Remove the cell identity's account-scoped auth-share file-data grant.

    Same lane as the container role cleanup: absent assignments are the
    desired end state, so a repeat run is a no-op.
    """
    if not auth_share_name():
        return
    principal = (state.get("resources") or {}).get("identity_principal_id")
    if not principal:
        return
    account_scope = storage_account_scope(env)
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/{}".format(
        env["subscription"], FILE_DATA_PRIVILEGED_CONTRIBUTOR_ROLE
    )
    assignments, _, _ = az_command(env, ["role", "assignment", "list", "--scope", account_scope, "--all"])
    for item in assignments or []:
        if (
            str(item.get("scope", "")).lower() == account_scope.lower()
            and str(item.get("principalId", "")).lower() == str(principal).lower()
            and str(item.get("roleDefinitionId", "")).lower() == expected_role.lower()
            and item.get("id")
        ):
            _, rc, stderr = az_command(env, ["role", "assignment", "delete", "--ids", item["id"]], check=False)
            if rc != 0:
                raise ValidationError("exact auth-share role assignment deletion failed: {}".format(stderr))


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
    delete_auth_share_role(env, state)
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
        if state["phase"] not in ("failed-retained", "result-published", "needs-decision", "running", "reattaching", "collected"):
            raise ValidationError("cell phase does not own retainable failure capacity")
        if state["phase"] == "collected" and (state.get("result") or {}).get("outcome") in ("passed", "checks-passed"):
            raise ValidationError("a passed collected cell closes with its exact head; retain-failure owns only failed outcomes")
        cleanup_compute(env, state)
        state["resources"]["identities"]["worktree"] = wait_exact_disk_detached(
            env, state["resources"]["worktree_disk_id"],
            state["resources"]["identities"]["worktree"], "validation worktree",
        )
        transition(env, state, "failed-retained", "exact disposable compute removed; worktree retained")
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
            "{} FM_TEST_SKIP_HERDR=1 bin/fm-behavior-shards.sh --run {} {} results/executed-{}.tsv".format(
                CELL_HOST_CAPABILITY_DECLARATION, shard, count, shard
            ),
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


def materialize_shard_repo(request, extracted):
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
    return repo


def prepare_shard_runner(env, state, blob, request, extracted, plan):
    sku = plan["sku"]
    key = request["request_digest"]
    existing = state.setdefault("shard_runs", {}).get(key)
    if existing:
        expected = {
            "blob": blob,
            "sku": sku,
            "round": request["round"],
            "shard": request["shard"],
            "head": request["repository"]["head"],
            "command_digest": request["command_digest"],
        }
        if any(existing.get(name) != value for name, value in expected.items()):
            raise ValidationError("recorded shard runner identity differs from the exact request")
        # Every pass re-downloads a still-pending request into a clean
        # extraction, which drops the previously materialized clone; the
        # retry and resume paths both need the exact repo back at its
        # recorded path.
        if not Path(existing["repo"]).is_dir():
            materialize_shard_repo(request, extracted)
        return existing
    repo = materialize_shard_repo(request, extracted)
    invocation = plan["invocation"]
    # A round may stage more than one request on the same shard constituent
    # (behavior tests plus lint). The constituent's invocation id is one-shot,
    # so only the first record may claim it; every later record derives its
    # own deterministic invocation from its request digest.
    claimed = any(
        value.get("invocation") == invocation
        and value.get("request_digest") != key
        for value in state.get("shard_runs", {}).values()
    )
    if claimed:
        invocation = "azr-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:12]
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
        "snapshot_bundle": str(extracted / "snapshot.bundle"),
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


def follow_shard_lineage(env, record):
    """Rebind the record to the newest retry descendant of its invocation.

    A runner retry after proven absence creates a fresh invocation whose
    parent_invocation points at the fenced one; the shard record must follow
    that chain or every later resume and response collection would keep
    addressing the permanently fenced ancestor.
    """
    directory = runner_state_dir(env)
    current = record["invocation"]
    while True:
        advanced = None
        for path in directory.glob("azr-*.json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if (
                value.get("parent_invocation") == current
                and (value.get("request") or {}).get("command_digest") == record["command_digest"]
            ):
                advanced = value["invocation"]
                break
        if advanced is None:
            return current
        current = advanced


def run_shard_invocations(env, state, records):
    processes = []
    runner = ROOT / "bin" / "fm-azure-runner.sh"
    rebound = False
    for record in records:
        followed = follow_shard_lineage(env, record)
        if followed != record["invocation"]:
            record["invocation"] = followed
            rebound = True
    if rebound:
        save_state(env, state)
    for record in records:
        runner_state = runner_state_dir(env) / (record["invocation"] + ".json")
        if runner_state.is_file():
            try:
                probe = json.loads(runner_state.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError("recorded shard runner state is unreadable: {}".format(exc))
            probe_digest = (probe.get("request") or {}).get("command_digest")
            if probe_digest is not None and probe_digest != record["command_digest"]:
                # The state at this invocation belongs to a different request
                # that shared the id (two records on one shard constituent):
                # retrying it would rerun the other record's command forever.
                # Rebind this record to its own derived invocation instead.
                record["invocation"] = "azr-" + hashlib.sha256(
                    record["request_digest"].encode("utf-8")
                ).hexdigest()[:12]
                save_state(env, state)
                runner_state = runner_state_dir(env) / (record["invocation"] + ".json")
        operation = [str(runner), "resume", "--invocation", record["invocation"]]
        if runner_state.is_file():
            try:
                value = json.loads(runner_state.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise ValidationError("recorded shard runner state is unreadable: {}".format(exc))
            if value.get("phase") == "complete":
                continue
            if value.get("phase") == "absent-fenced":
                # The fenced invocation can never rerun; the runner's retry
                # lane reproves absence and creates the lineage descendant
                # that the next pass rebinds to.
                operation = [
                    str(runner), "retry",
                    "--invocation", record["invocation"],
                    "--confirm-run",
                    "--confirm-subscription", env["subscription"],
                ]
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
        # A retry that completed inside this pass created a lineage
        # descendant; rebind before response collection addresses the record.
        followed = follow_shard_lineage(env, record)
        if followed != record["invocation"]:
            record["invocation"] = followed
            rebound = True
        if process.returncode == 125 or process.returncode < 0:
            failures.append("{} rc={}".format(record["invocation"], process.returncode))
    # The tails and any rebind must survive the failure raise below, or a
    # refused transport leaves no durable ground truth for the operator.
    save_state(env, state)
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
    control_probe_at = time.monotonic()
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
            # A guest whose control command already ended can never publish
            # another shard request, so waiting out the deadline only delays
            # the observe that records the terminal outcome. Attempt 1 of
            # generation 005 burned its whole 47-minute wall budget this way
            # after the guest died in bootstrap. Probe at most every 30
            # seconds; observe stays the sole owner of the state transition.
            if time.monotonic() >= control_probe_at:
                control_probe_at = time.monotonic() + 30
                execution, _view = run_command_status(env, state)
                if execution in ("Succeeded", "Failed", "Canceled", "TimedOut"):
                    print("AZURE VALIDATION CONTROL TERMINAL cell={} control_state={} pending=0".format(cell, execution))
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
        print("AZURE VALIDATION QUEUE empty active=0 queued=0 lanes_used=0/{}".format(env["lanes"]))
        return
    occupied = [state for _, state in rows if state.get("phase") in LANE_PHASES]
    queued = [state for _, state in rows if state.get("phase") == "queued"]
    print("AZURE VALIDATION LANES used={}/{} queued={}".format(
        len(occupied), env["lanes"], len(queued)
    ))
    for _, state in rows:
        lane = state.get("lane")
        print("cell={} phase={} lane={} task={} head={} class={} attempt={}".format(
            state.get("cell"), state.get("phase"),
            lane if isinstance(lane, int) else "-",
            state.get("request", {}).get("task"),
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
        allowed, reason = replacement_allowed(value["state"], value["vm_presence"])
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
    seed_parser = commands.add_parser("auth-seed")
    seed_parser.add_argument("--codex")
    seed_parser.add_argument("--claude")
    seed_parser.add_argument("--apply", action="store_true")
    seed_parser.add_argument("--confirm-seed", action="store_true")
    seed_parser.add_argument("--confirm-subscription")
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
        # Planning a seed is a purely local credential read; only the upload
        # needs a cloud scope, so a plan works without Azure environment.
        if args.command == "auth-seed" and args.apply:
            cloud = True
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
        elif args.command == "auth-seed":
            auth_seed(env, args)
        return 0
    except ValidationError as exc:
        print("AZURE VALIDATION FAILED: {}".format(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
