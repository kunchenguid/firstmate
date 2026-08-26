#!/usr/bin/env python3
"""Host-side controller for one-shot private Azure command runners.

The script binds a clean committed Git snapshot to a canonical command
request, creates one private controller VM with a container-scoped UAMI, drives
an isolated networkless child through Azure Managed Run Command, verifies the
bounded result, and removes only resources whose recorded identities match the
invocation.

See docs/azure-runner.md and `bin/fm-azure-runner.sh help` for the operator
contract. This file intentionally uses only the Python standard library and the
installed Azure CLI.
"""

import argparse
import base64
import contextlib
import datetime as dt
import email.utils
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid


ROOT = Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "docs" / "azure-runner" / "invocation.json"
GUEST = ROOT / "bin" / "fm-azure-runner-guest.sh"
EXECUTOR = ROOT / "bin" / "fm-azure-runner-exec.py"
AGENT_FLEET_INSTALLER = ROOT / "bin" / "fm-azure-runner-agent-fleet-install.py"
WORKER_LIFECYCLE = ROOT / "bin" / "fm-worker-lifecycle.py"
CONTAINER = "validation-shards"
CONTROL_CONTAINER = "runner-control"
SCHEMA = "fm.azure-command/v1"
RESULT_SCHEMA = "fm.azure-command-result/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
SAFE_INVOCATION = re.compile(r"^azr-[a-z0-9]{12}(?:-a(?:[2-9]|[1-9][0-9]+))?$")
SAFE_ARTIFACT = re.compile(r"^(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._/+@:-]{1,240}$")
SAFE_PUBLIC_GIT_REMOTE = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?$")
SAFE_PUBLIC_GIT_REF = re.compile(
    r"^refs/(?:heads/[A-Za-z0-9._/-]{1,200}|pull/[1-9][0-9]*/head)$"
)
LOCAL_COMMAND_TIMEOUT_SECONDS = 300
# A TrustedLaunch VM deployment routinely outlives the general command bound,
# especially with sibling shard deployments in flight; the ARM call gets its
# own generous-but-bounded deadline.
DEPLOYMENT_TIMEOUT_SECONDS = 900
COST_QUERY_TIMEOUT_SECONDS = 60
COST_RETRY_DEADLINE_SECONDS = 900
COST_CACHE_MAX_AGE_SECONDS = 4 * 60 * 60
MAX_STAGING_INPUT_BYTES = 1024**3
MAX_BOOTSTRAP_NETWORK_BYTES = 16 * 1024**3
MAX_RESULT_UPLOAD_BYTES = 600 * 1024**2
BOOTSTRAP_RATE_BITS_PER_SECOND = 1_000_000
MAX_BILLABLE_LIFETIME_HOURS = 24
STRICT_COST_ADMISSION_MODE = "strict"
COMMISSIONING_COST_ADMISSION_MODE = "commissioning-bounded"
TRANSIENT_SHARED_CAPACITY_REFUSALS = frozenset({
    "exact selected-family observed-plus-reserved capacity is exhausted",
    "specialized observed-plus-reserved demand exceeds its shared 40-vCPU shape",
    "combined observed-plus-reserved demand would consume the shared East US ceiling",
})
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
# Runaway-automation backstops, not budgets: spend is governed by the
# durable reservations and the dollar limit. The original 2000-op
# lifetime bootstrap bucket was legitimately exhausted by the
# multi-generation commissioning campaign (generation 054 ground
# truth), so the ceilings now sit an order of magnitude above any
# single campaign while still bounding a runaway loop.
RUNNER_CONTROL_OPERATION_CEILING = 20_000
RUNNER_STORAGE_OPERATION_CEILING = 20_000
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
    "Standard_E4as_v7": "StandardEasv7Family",
    "Standard_E4as_v6": "standardEav6Family",
}
SKU_VCPUS = {sku: 4 for sku in SKU_FAMILY}
SKU_MEMORY_GIB = {sku: (32 if sku.startswith("Standard_E") else 16) for sku in SKU_FAMILY}
COMMISSIONING_SKU_POOL = (
    "Standard_D4as_v7",
    "Standard_D4as_v6",
    "Standard_D4s_v6",
    "Standard_D4ads_v7",
    "Standard_D4ads_v6",
    "Standard_E4as_v7",
    "Standard_E4as_v6",
    "Standard_D4ds_v6",
)


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


def run(command, cwd=None, check=True, capture=True, timeout_seconds=LOCAL_COMMAND_TIMEOUT_SECONDS, env=None):
    try:
        result = subprocess.run(
            command,
            cwd=str(cwd) if cwd else None,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
            timeout=timeout_seconds,
            env=env,
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


def credential_prompt_refuser():
    executable = shutil.which("false", path="/usr/bin:/bin")
    if not executable:
        raise RunnerError(
            "public Git proof requires an executable false command in /usr/bin or /bin"
        )
    return executable


def public_git(repo, *args, check=True):
    askpass = credential_prompt_refuser()
    git_env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "LANG": "C",
        "LC_ALL": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": askpass,
        "SSH_ASKPASS": askpass,
    }
    command = [
        "git", "-c", "credential.helper=", "-c", "http.extraHeader=",
        "-c", "protocol.file.allow=never", "-C", str(repo),
    ] + list(args)
    return run(command, check=check, env=git_env)


def validate_public_source_ref(value):
    if not isinstance(value, str) or not SAFE_PUBLIC_GIT_REF.fullmatch(value):
        raise RunnerError("public source ref is not an allow-listed branch or PR-head ref")
    if (
        any(m in value for m in ("..", "//", "@{", "\\"))
        or value.endswith(("/", ".", ".lock"))
    ):
        raise RunnerError("public source ref has an unsafe shape")
    return value


def public_origin_proof(
    repo, remote, candidate_commit, expected=None, source_ref=None,
    source_ancestors=(), private_source=False,
):
    if not SAFE_PUBLIC_GIT_REMOTE.match(remote) or "@" in remote:
        raise RunnerError("Azure private controller requires a credential-free public GitHub HTTPS origin")
    if source_ref is not None:
        source_ref = validate_public_source_ref(source_ref)
    with tempfile.TemporaryDirectory(prefix="fm-azure-public-proof-") as temporary:
        proof_repo = Path(temporary)
        public_git(proof_repo, "init", "--bare")
        advertised = public_git(proof_repo, "ls-remote", "--symref", remote, "HEAD").stdout.splitlines()
        symrefs = [line.split("\t", 1)[0][5:] for line in advertised if line.startswith("ref: ") and line.endswith("\tHEAD")]
        heads = [line.split("\t", 1)[0] for line in advertised if line.endswith("\tHEAD") and not line.startswith("ref: ")]
        if symrefs != ["refs/heads/main"] or len(heads) != 1 or not re.match(r"^[0-9a-f]{40,64}$", heads[0]):
            raise RunnerError("public origin must advertise one exact refs/heads/main default")
        default_ref = symrefs[0]
        default_head = heads[0]
        exact = public_git(proof_repo, "ls-remote", remote, default_ref).stdout.splitlines()
        if exact != ["{}\t{}".format(default_head, default_ref)]:
            raise RunnerError("public origin default-head advertisement changed or is ambiguous")
        public_git(
            proof_repo, "fetch", "--no-tags", "--force", remote,
            "+{}:refs/fm-azure-runner/public-main".format(default_ref),
        )
        fetched_default = public_git(
            proof_repo, "rev-parse", "--verify", "refs/fm-azure-runner/public-main"
        ).stdout.strip()
        if fetched_default != default_head:
            raise RunnerError("fresh public default-head fetch differs from its advertisement")

        selected_ref = source_ref or default_ref
        selected_head = default_head
        fetched_ref = "refs/fm-azure-runner/public-main"
        if private_source:
            if source_ref is None:
                raise RunnerError("private parent snapshot requires one exact source ref")
            selected_head = candidate_commit
        elif source_ref is not None:
            source_lines = public_git(proof_repo, "ls-remote", remote, source_ref).stdout.splitlines()
            if source_lines != ["{}\t{}".format(candidate_commit, source_ref)]:
                raise RunnerError("candidate commit is not the exact advertised public source-ref head")
            fetched_ref = "refs/fm-azure-runner/public-source"
            public_git(
                proof_repo, "fetch", "--no-tags", "--force", remote,
                "+{}:{}".format(source_ref, fetched_ref),
            )
            selected_head = public_git(proof_repo, "rev-parse", "--verify", fetched_ref).stdout.strip()
            if selected_head != candidate_commit:
                raise RunnerError("fresh public source-ref fetch differs from the candidate commit")
        elif public_git(
            proof_repo, "merge-base", "--is-ancestor", candidate_commit, fetched_ref, check=False
        ).returncode != 0:
            raise RunnerError("candidate commit is not reachable from the exact public origin/main head")

        object_repo = repo if private_source else proof_repo
        object_git = git if private_source else public_git
        ancestors = []
        for ancestor in source_ancestors:
            if not isinstance(ancestor, str) or not re.fullmatch(r"[0-9a-f]{40,64}", ancestor):
                raise RunnerError("public source ancestor is not an exact commit identity")
            if ancestor in ancestors:
                continue
            if object_git(object_repo, "cat-file", "-t", ancestor, check=False).stdout.strip() != "commit":
                raise RunnerError("public source ancestor is not a fetched commit")
            if object_git(
                object_repo, "merge-base", "--is-ancestor", ancestor, candidate_commit,
                check=False,
            ).returncode != 0:
                raise RunnerError("public source ancestor is not reachable from the candidate")
            ancestors.append(ancestor)

        proof_identity = {
            "remote": remote,
            "default_ref": default_ref,
            "default_head": default_head,
            "source_ref": selected_ref,
            "source_head": selected_head,
            "source_ancestors": ancestors,
        }
        # Only the source lineage binds the code under test. The default-branch
        # tip is operator-mutable global state: holding it equal would refuse
        # every in-flight run whenever an unrelated PR merges.
        binding_keys = ("remote", "source_ref", "source_head", "source_ancestors")
        if expected is not None and any(
            expected.get(key) != proof_identity[key] for key in binding_keys
        ):
            raise RunnerError("public origin/source identity changed after request preparation")
        if object_git(object_repo, "cat-file", "-t", candidate_commit).stdout.strip() != "commit":
            raise RunnerError("candidate source object is not an exact commit")
        tree = object_git(object_repo, "rev-parse", "{}^{{tree}}".format(candidate_commit)).stdout.strip()
        if not re.match(r"^[0-9a-f]{40,64}$", tree) or object_git(object_repo, "cat-file", "-t", tree).stdout.strip() != "tree":
            raise RunnerError("candidate source commit tree identity is malformed")
        proof_identity["tree"] = tree
        return proof_identity


def private_bundle_origin_proof(
    repo, remote, candidate_commit, source_ref, source_ancestors=(), expected=None
):
    if not SAFE_PUBLIC_GIT_REMOTE.match(remote) or "@" in remote:
        raise RunnerError(
            "Azure private controller requires a credential-free GitHub HTTPS origin identity"
        )
    source_ref = validate_public_source_ref(source_ref)
    ancestors = []
    for ancestor in source_ancestors:
        if not isinstance(ancestor, str) or not re.fullmatch(r"[0-9a-f]{40,64}", ancestor):
            raise RunnerError("private source ancestor is not an exact commit identity")
        if ancestor in ancestors:
            continue
        if git(repo, "cat-file", "-t", ancestor, check=False).stdout.strip() != "commit":
            raise RunnerError("private source ancestor is not present in the exact checkout")
        if git(
            repo, "merge-base", "--is-ancestor", ancestor, candidate_commit, check=False
        ).returncode != 0:
            raise RunnerError("private source ancestor is not reachable from the candidate")
        ancestors.append(ancestor)
    if git(repo, "cat-file", "-t", candidate_commit).stdout.strip() != "commit":
        raise RunnerError("private candidate source object is not an exact commit")
    tree = git(repo, "rev-parse", "{}^{{tree}}".format(candidate_commit)).stdout.strip()
    if (
        not re.fullmatch(r"[0-9a-f]{40,64}", tree)
        or git(repo, "cat-file", "-t", tree).stdout.strip() != "tree"
    ):
        raise RunnerError("private candidate source tree identity is malformed")
    proof_identity = {
        "remote": remote,
        "default_ref": None,
        "default_head": None,
        "source_ref": source_ref,
        "source_head": candidate_commit,
        "source_ancestors": ancestors,
        "tree": tree,
    }
    binding_keys = ("remote", "source_ref", "source_head", "source_ancestors")
    if expected is not None and any(
        expected.get(key) != proof_identity[key] for key in binding_keys
    ):
        raise RunnerError("private bundle source identity changed after request preparation")
    return proof_identity


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def require_identifier(label, value):
    if not SAFE_ID.match(value):
        raise RunnerError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_capacity_fence(value):
    if not re.fullmatch(r"[0-9a-f]{64}", str(value)):
        raise RunnerError("capacity fence must be 64 lowercase hex characters")
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
    if max_concurrency < 1 or max_concurrency > 16:
        raise RunnerError("FM_AZURE_RUNNER_MAX_CONCURRENCY must be between 1 and 16")
    try:
        capacity_wait_seconds = int(
            os.environ.get("FM_AZURE_RUNNER_CAPACITY_WAIT_SECONDS", "7200")
        )
        capacity_poll_seconds = int(
            os.environ.get("FM_AZURE_RUNNER_CAPACITY_POLL_SECONDS", "5")
        )
    except ValueError:
        raise RunnerError(
            "FM_AZURE_RUNNER_CAPACITY_WAIT_SECONDS and "
            "FM_AZURE_RUNNER_CAPACITY_POLL_SECONDS must be integers"
        )
    if not 0 <= capacity_wait_seconds <= 86400:
        raise RunnerError(
            "FM_AZURE_RUNNER_CAPACITY_WAIT_SECONDS must be between 0 and 86400"
        )
    if not 1 <= capacity_poll_seconds <= 60:
        raise RunnerError(
            "FM_AZURE_RUNNER_CAPACITY_POLL_SECONDS must be between 1 and 60"
        )
    budget_limit = int(os.environ.get("FM_AZURE_RUNNER_BUDGET_LIMIT_USD", "1000"))
    if budget_limit not in (1000, 1500):
        raise RunnerError("FM_AZURE_RUNNER_BUDGET_LIMIT_USD must be 1000 or 1500")
    cost_admission_mode = os.environ.get("FM_AZURE_RUNNER_COST_ADMISSION_MODE", STRICT_COST_ADMISSION_MODE)
    if cost_admission_mode not in {STRICT_COST_ADMISSION_MODE, COMMISSIONING_COST_ADMISSION_MODE}:
        raise RunnerError("FM_AZURE_RUNNER_COST_ADMISSION_MODE must be strict or commissioning-bounded")
    cell_ordinal_text = os.environ.get("FM_AZURE_RUNNER_CELL_ORDINAL")
    try:
        cell_ordinal = int(cell_ordinal_text) if cell_ordinal_text is not None else None
    except ValueError:
        raise RunnerError("FM_AZURE_RUNNER_CELL_ORDINAL must be an integer from 1 through 16")
    if cell_ordinal is not None and not 1 <= cell_ordinal <= 16:
        raise RunnerError("FM_AZURE_RUNNER_CELL_ORDINAL must be an integer from 1 through 16")
    home = Path(os.environ["FM_HOME"]).resolve()
    state_dir = Path(os.environ.get("FM_AZURE_RUNNER_STATE_DIR", str(home / "state" / "azure-runner"))).resolve()
    return {
        "tenant": tenant,
        "subscription": subscription,
        "prefix": prefix,
        "storage": storage,
        "operator_data_plane_ip": os.environ.get("FM_AZURE_OPERATOR_DATA_PLANE_IP", ""),
        "control_storage": "st{}ctl01".format(prefix),
        "controller_identity": "id-{}-validation-shards".format(prefix),
        "owner": owner,
        "deployment_generation": generation,
        "resource_group": resource_group,
        "max_concurrency": max_concurrency,
        "capacity_wait_seconds": capacity_wait_seconds,
        "capacity_poll_seconds": capacity_poll_seconds,
        "budget_limit": budget_limit,
        "cost_admission_mode": cost_admission_mode,
        "cell_ordinal": cell_ordinal,
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



def locked_python_manifest(repo):
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
        if not re.match(r"^https://files\.pythonhosted\.org/packages/[A-Za-z0-9/_.-]+\.whl$", selected["url"]):
            raise RunnerError("locked Agent Fleet wheel URL is outside the reviewed credential-free PyPI file origin")
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
    return lock_path, wheels



def verify_self_contained_private_bundle(bundle, commit, source_ref):
    heads = git(ROOT, "bundle", "list-heads", str(bundle)).stdout.splitlines()
    expected_head = "{} {}".format(commit, source_ref)
    if heads != [expected_head]:
        raise RunnerError("private snapshot must contain only the exact source-ref head")
    with tempfile.TemporaryDirectory(prefix="fm-azure-bundle-verify-") as temporary:
        verification_repo = Path(temporary) / "repo.git"
        run(["git", "init", "--bare", str(verification_repo)])
        run(["git", "-C", str(verification_repo), "bundle", "verify", str(bundle)])
        run([
            "git", "-C", str(verification_repo), "fetch", "--no-tags", str(bundle),
            "+{}:refs/fm-azure-runner/verified".format(source_ref),
        ])
        verified = git(
            verification_repo, "rev-parse", "--verify", "refs/fm-azure-runner/verified"
        ).stdout.strip()
        shallow = git(verification_repo, "rev-parse", "--is-shallow-repository").stdout.strip()
        if verified != commit or shallow != "false":
            raise RunnerError("private snapshot source graph is incomplete or has the wrong head")


def create_private_snapshot_from_head(repo, destination, commit, source_ref):
    shallow = git(repo, "rev-parse", "--is-shallow-repository").stdout.strip()
    if shallow != "false":
        raise RunnerError("direct private snapshot requires a complete non-shallow source graph")
    with tempfile.TemporaryDirectory(prefix="fm-azure-bundle-stage-") as temporary:
        staging_repo = Path(temporary) / "repo.git"
        run(["git", "init", "--bare", str(staging_repo)])
        run([
            "git", "-C", str(staging_repo), "fetch", "--no-tags", "--force", str(repo),
            "+{}:{}".format(commit, source_ref),
        ])
        staged = git(staging_repo, "rev-parse", "--verify", source_ref).stdout.strip()
        if staged != commit:
            raise RunnerError("direct private snapshot staging changed the exact source head")
        run(["git", "-C", str(staging_repo), "bundle", "create", str(destination), source_ref])
    verify_self_contained_private_bundle(destination, commit, source_ref)


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


def runner_sku_for_environment(env):
    configured_sku = os.environ.get("FM_AZURE_RUNNER_SKU")
    if env["cost_admission_mode"] == COMMISSIONING_COST_ADMISSION_MODE:
        if env["cell_ordinal"] is None:
            raise RunnerError("commissioning-bounded requires FM_AZURE_RUNNER_CELL_ORDINAL from 1 through 16")
        selected_sku = COMMISSIONING_SKU_POOL[(env["cell_ordinal"] - 1) // 2]
        if configured_sku is not None and configured_sku != selected_sku:
            raise RunnerError("FM_AZURE_RUNNER_SKU differs from the deterministic commissioning cell allocation")
        return selected_sku
    if env["cell_ordinal"] is not None:
        raise RunnerError("FM_AZURE_RUNNER_CELL_ORDINAL is accepted only for commissioning-bounded")
    return configured_sku or "Standard_D4as_v6"


def prepare(env, args, parent_state=None):
    repo = Path(args.repo or os.getcwd()).resolve()
    top = Path(git(repo, "rev-parse", "--show-toplevel").stdout.strip()).resolve()
    if top != repo:
        repo = top
    dirty = git(repo, "status", "--porcelain", "--untracked-files=all").stdout
    if dirty:
        raise RunnerError("repository must be an exact clean committed snapshot; tracked or untracked changes are present")
    branch = git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if (
        branch.returncode != 0
        and getattr(args, "public_ref", None) is None
        and getattr(args, "source_ref", None) is None
    ):
        raise RunnerError(
            "repository must be on a named committed branch unless an exact source ref is supplied"
        )
    commit = git(repo, "rev-parse", "HEAD").stdout.strip()
    remote = git(repo, "remote", "get-url", "origin").stdout.strip()
    private_snapshot_source = None
    private_snapshot_from_head = bool(getattr(args, "private_snapshot_from_head", False))
    if args.private_snapshot_bundle and private_snapshot_from_head:
        raise RunnerError("choose one private snapshot input: bundle or exact HEAD")
    if args.private_snapshot_bundle:
        private_snapshot_arg = Path(args.private_snapshot_bundle)
        private_snapshot_source = private_snapshot_arg.resolve()
        if private_snapshot_arg.is_symlink() or not private_snapshot_source.is_file():
            raise RunnerError("private snapshot must be a regular non-link Git bundle")
        if private_snapshot_source.stat().st_size > MAX_STAGING_INPUT_BYTES:
            raise RunnerError("private snapshot exceeds the one-GiB staging bound")
        if not args.source_ref:
            raise RunnerError("private snapshot requires one exact source ref")
        heads = git(repo, "bundle", "list-heads", str(private_snapshot_source)).stdout.splitlines()
        expected_head = "{} {}".format(commit, args.source_ref)
        accepted_heads = [expected_head]
        if not args.capacity_parent:
            accepted_heads.append("{} HEAD".format(commit))
        if heads not in [[value] for value in accepted_heads]:
            raise RunnerError("private snapshot must contain only the exact source head")
        run(["git", "bundle", "verify", str(private_snapshot_source)], cwd=repo)
    if getattr(args, "public_ref", None) and args.source_ref:
        raise RunnerError("choose one exact source identity: --source-ref or --public-ref")
    source_ancestors = tuple(getattr(args, "public_ancestor", None) or ())
    if private_snapshot_from_head:
        if args.capacity_parent or not args.source_ref:
            raise RunnerError("direct private HEAD snapshot requires one exact source ref and no capacity parent")
        public = public_origin_proof(
            repo, remote, commit,
            source_ref=args.source_ref,
            source_ancestors=source_ancestors,
            private_source=True,
        )
    elif private_snapshot_source is not None and not args.capacity_parent:
        public = private_bundle_origin_proof(
            repo,
            remote,
            commit,
            args.source_ref,
            source_ancestors=source_ancestors,
        )
    else:
        public = public_origin_proof(
            repo, remote, commit,
            source_ref=getattr(args, "public_ref", None) or args.source_ref,
            source_ancestors=source_ancestors,
            private_source=private_snapshot_source is not None,
        )
    private_snapshot_requested = private_snapshot_source is not None or private_snapshot_from_head
    tree = public["tree"]

    task = require_identifier("task", args.task)
    generation = require_identifier("generation", args.generation)
    resource_class = args.resource_class
    if resource_class not in RESOURCE_CLASSES:
        raise RunnerError("unknown resource class: {}".format(resource_class))
    limits = dict(RESOURCE_CLASSES[resource_class])
    selected_sku = runner_sku_for_environment(env)
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
    private_snapshot_path = None
    private_snapshot_digest = None
    private_snapshot_bytes = 0
    if private_snapshot_requested:
        private_snapshot_path = payload_dir / "snapshot.bundle"
        if private_snapshot_from_head:
            create_private_snapshot_from_head(
                repo, private_snapshot_path, commit, args.source_ref
            )
        else:
            shutil.copyfile(str(private_snapshot_source), str(private_snapshot_path))
        os.chmod(private_snapshot_path, 0o600)
        private_snapshot_digest = "sha256:" + sha256_file(private_snapshot_path)
        private_snapshot_bytes = private_snapshot_path.stat().st_size
        if private_snapshot_bytes > MAX_STAGING_INPUT_BYTES:
            raise RunnerError("private snapshot exceeds the one-GiB staging bound")
    source_identity = {
        "remote": remote,
        "default_ref": public["default_ref"],
        "default_head": public["default_head"],
        "source_ref": public["source_ref"],
        "source_head": public["source_head"],
        "source_ancestors": public.get("source_ancestors", []),
        "commit": commit,
        "tree": tree,
    }
    snapshot_digest = "sha256:" + sha256_bytes(canonical_bytes(source_identity))

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
    lock_path = repo / "tools" / "agent-fleet" / "uv.lock"
    if resource_class == "crosscheck-tool" and not lock_path.is_file():
        locked_python = {"lock_digest": None, "wheels": []}
    else:
        lock_path, wheel_manifest = locked_python_manifest(repo)
        locked_python = {
            "lock_digest": "sha256:" + sha256_file(lock_path),
            "wheels": [
                {
                    key: item[key]
                    for key in ("name", "version", "file", "url", "digest", "bytes")
                }
                for item in wheel_manifest
            ],
        }
    prepared_at = now_utc()
    expires_at = prepared_at + dt.timedelta(hours=TTL_SCHEDULE_HOURS_AFTER_PREPARATION)
    request = {
        "schema": SCHEMA,
        "home_binding": env["home_binding"],
        "task": task,
        "generation": generation,
        "capacity_parent": (
            require_identifier("capacity parent", args.capacity_parent)
            if args.capacity_parent else None
        ),
        "capacity_reservation_vcpus": args.capacity_reservation_vcpus,
        "capacity_fence": (
            require_capacity_fence(args.capacity_fence)
            if getattr(args, "capacity_fence", None) else None
        ),
        "deployment_generation": env["deployment_generation"],
        "cost_admission_mode": env["cost_admission_mode"],
        "cell_ordinal": env["cell_ordinal"],
        "invocation": invocation,
        "attempt": attempt,
        "parent_invocation": parent_state["invocation"] if parent_state else None,
        "lineage_root_invocation": (
            parent_state["request"].get("lineage_root_invocation", parent_state["invocation"])
            if parent_state else invocation
        ),
        "fence": fence,
        "repository": {
            "source_mode": (
                (
                    "private-parent-bundle"
                    if args.capacity_parent
                    else (
                        "private-direct-bundle"
                        if private_snapshot_from_head
                        else "private-exact-bundle"
                    )
                )
                if private_snapshot_path
                else "public-github-https"
            ),
            "remote": remote,
            "default_ref": public["default_ref"],
            "default_head": public["default_head"],
            "source_ref": public["source_ref"],
            "source_head": public["source_head"],
            "source_ancestors": public.get("source_ancestors", []),
            "commit": commit,
            "tree": tree,
            "snapshot_digest": (
                private_snapshot_digest if private_snapshot_path else snapshot_digest
            ),
            "snapshot_bytes": private_snapshot_bytes,
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
            "agent_fleet_installer_digest": "sha256:" + sha256_file(AGENT_FLEET_INSTALLER),
        },
        "created_at": iso_utc(prepared_at),
        "compute_deallocation_deadline": iso_utc(expires_at),
    }
    if bool(request["capacity_parent"]) != bool(request["capacity_reservation_vcpus"]):
        raise RunnerError("capacity parent and reservation vCPUs must be supplied together")
    if request["capacity_parent"]:
        if not re.match(r"^azv-[a-z0-9]{12}$", request["capacity_parent"]):
            raise RunnerError("capacity parent must be an exact Azure validation cell id")
        if not 8 <= request["capacity_reservation_vcpus"] <= 64:
            raise RunnerError("capacity parent reservation must be 8-64 vCPUs")
    if private_snapshot_path:
        request["repository"]["input_blob"] = staging_prefix = "{}/{}/{}/{}/attempt-{}/snapshot.bundle".format(
            env["home_binding"].split(":", 1)[1][:16], task, generation, invocation, attempt
        )
    else:
        request["repository"]["input_blob"] = None
    request_digest = "sha256:" + sha256_bytes(canonical_bytes(request))
    request["request_digest"] = request_digest
    request_path = payload_dir / "request.json"
    request_path.write_bytes(canonical_bytes(request) + b"\n")
    os.chmod(request_path, 0o600)
    request_bytes = request_path.read_bytes()
    if len(request_bytes) > 48 * 1024:
        raise RunnerError("private controller request exceeds the bounded control-plane parameter allowance")
    input_digest = "sha256:" + sha256_bytes(request_bytes)
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
        "input_bytes": len(request_bytes),
        "input_path": str(request_path),
        "repository_root": str(repo),
        "staging": {
            "container": CONTAINER,
            "input_blob": request["repository"]["input_blob"],
            "input_blob_etag": None,
            "output_blob": staging_prefix + "/result.tar.gz",
            "control_container": CONTROL_CONTAINER,
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
            # DevTestLab requires the exact name shutdown-computevm-<vmName>;
            # anything else fails the deployment at the schedule resource.
            "ttl_schedule_name": "shutdown-computevm-{}".format(vm_name),
            "ttl_schedule_id": "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.DevTestLab/schedules/shutdown-computevm-{}".format(
                env["subscription"], env["resource_group"], vm_name
            ),
            "identities": {},
        },
        "events": [{"at": iso_utc(), "phase": "prepared", "note": "clean snapshot and digest-bound request created"}],
    }
    save_state(env, state, create=True)
    return state


def reprove_public_request(state):
    repository = state["request"]["repository"]
    repo = Path(state["repository_root"]).resolve()
    source_mode = repository.get("source_mode")
    private_source = source_mode in (
        "private-parent-bundle", "private-exact-bundle", "private-direct-bundle",
    )
    expected = {
        "remote": repository["remote"],
        "default_ref": repository["default_ref"],
        "default_head": repository["default_head"],
        "source_ref": repository["source_ref"],
        "source_head": repository["source_head"],
        "source_ancestors": repository.get("source_ancestors", []),
    }
    if source_mode == "private-exact-bundle":
        proof = private_bundle_origin_proof(
            repo,
            repository["remote"],
            repository["commit"],
            repository["source_ref"],
            source_ancestors=repository.get("source_ancestors", []),
            expected=expected,
        )
    else:
        proof = public_origin_proof(
            repo, repository["remote"], repository["commit"],
            expected=expected,
            source_ref=(
                repository["source_ref"]
                if repository["source_ref"] != repository["default_ref"]
                else None
            ),
            source_ancestors=repository.get("source_ancestors", []),
            private_source=private_source,
        )
    if private_source:
        snapshot_path = Path(state["input_path"]).parent / "snapshot.bundle"
        if (
            not snapshot_path.is_file()
            or "sha256:" + sha256_file(snapshot_path) != repository["snapshot_digest"]
            or snapshot_path.stat().st_size != repository["snapshot_bytes"]
        ):
            raise RunnerError("private snapshot changed after request preparation")
    if proof["tree"] != repository["tree"]:
        raise RunnerError("public request tree changed after preparation")


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


def effective_role_assignments(env, principal_id):
    assignments, _, _ = az_command(env, [
        "role", "assignment", "list", "--assignee-object-id", principal_id, "--all",
        "--include-inherited", "--include-groups",
    ])
    if not isinstance(assignments, list):
        raise RunnerError("effective RBAC assignment expansion is unreadable")
    return assignments


def storage_network_access_is_exact(resource, operator_data_plane_ip, ip_rule_key="value"):
    properties = resource.get("properties", resource)
    network_acls = properties.get("networkAcls") or properties.get("networkRuleSet") or {}
    ip_rules = network_acls.get("ipRules") or []
    if not operator_data_plane_ip:
        return properties.get("publicNetworkAccess") == "Disabled" and not ip_rules
    return (
        properties.get("publicNetworkAccess") == "Enabled"
        and len(ip_rules) == 1
        and isinstance(ip_rules[0], dict)
        and ip_rules[0].get(ip_rule_key) == operator_data_plane_ip
        and ip_rules[0].get("action") == "Allow"
    )


def foundation_gate(env):
    storage_id = exact_id(env, "Microsoft.Storage", "storageAccounts", env["storage"])
    control_storage_id = exact_id(env, "Microsoft.Storage", "storageAccounts", env["control_storage"])
    controller_identity_id = exact_id(env, "Microsoft.ManagedIdentity", "userAssignedIdentities", env["controller_identity"])
    validation_container_id = storage_id + "/blobServices/default/containers/" + CONTAINER
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
        or not storage_network_access_is_exact(storage, env["operator_data_plane_ip"])
        or properties.get("allowSharedKeyAccess") is not False
        or properties.get("allowBlobPublicAccess") is not False
        or properties.get("supportsHttpsTrafficOnly") is not True
        or properties.get("minimumTlsVersion") != "TLS1_2"
        or network_acls.get("defaultAction") != "Deny"
        or network_acls.get("bypass") != "None"
    ):
        raise RunnerError("foundation storage identity/private-security contract is not exact")

    control, _, _ = az_command(env, ["resource", "show", "--ids", control_storage_id, "--api-version", "2023-05-01"])
    verify_foundation_tags(env, control, "runner control storage")
    control_properties = control.get("properties", control)
    control_acls = control_properties.get("networkAcls") or {}
    if (
        str(control.get("id", "")).lower() != control_storage_id.lower()
        or control.get("location") != "eastus"
        or control.get("kind") != "StorageV2"
        or (control.get("sku") or {}).get("name") != "Standard_LRS"
        or not storage_network_access_is_exact(control, env["operator_data_plane_ip"])
        or control_properties.get("allowSharedKeyAccess") is not False
        or control_properties.get("allowBlobPublicAccess") is not False
        or control_properties.get("defaultToOAuthAuthentication") is not True
        or control_acls.get("defaultAction") != "Deny"
        or control_acls.get("bypass") != "None"
    ):
        raise RunnerError("runner control storage exact zero-data security contract is not exact")
    control_container, _, _ = az_command(env, [
        "resource", "show", "--ids", runner_control_id(env), "--api-version", "2023-05-01",
    ])
    control_metadata = control_container.get("properties", {}).get("metadata") or {}
    allowed_control_metadata = {"schema", "deploymentgeneration", "lockowner", "lockfence", "lockexpiry"}
    if (
        str(control_container.get("id", "")).lower() != runner_control_id(env).lower()
        or control_container.get("properties", {}).get("publicAccess") != "None"
        or control_metadata.get("schema") != "fm-azure-runner-control-v1"
        or control_metadata.get("deploymentgeneration") != env["deployment_generation"]
        or not set(control_metadata).issubset(allowed_control_metadata)
        or not (control_container.get("etag") or control_container.get("properties", {}).get("etag"))
    ):
        raise RunnerError("runner control container identity/ETag contract is not exact")
    controller_identity, _, _ = az_command(env, [
        "resource", "show", "--ids", controller_identity_id, "--api-version", "2023-01-31",
    ])
    verify_foundation_tags(env, controller_identity, "runner controller identity")
    principal_id = controller_identity.get("properties", {}).get("principalId") or controller_identity.get("principalId")
    client_id = controller_identity.get("properties", {}).get("clientId") or controller_identity.get("clientId")
    if str(controller_identity.get("id", "")).lower() != controller_identity_id.lower() or controller_identity.get("location") != "eastus" or not principal_id or not client_id:
        raise RunnerError("runner controller UAMI identity is not exact")
    assignments = effective_role_assignments(env, principal_id)
    expected_role = "/subscriptions/{}/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe".format(env["subscription"])
    if (
        len(assignments) != 1
        or str(assignments[0].get("principalId", "")).lower() != str(principal_id).lower()
        or str(assignments[0].get("scope", "")).lower() != validation_container_id.lower()
        or str(assignments[0].get("roleDefinitionId", "")).lower() != expected_role.lower()
    ):
        raise RunnerError("runner controller UAMI must have only exact validation container data scope")
    env["controller_identity_client_id"] = client_id

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


def validate_runner_sku_record(item, sku):
    if item.get("restrictions"):
        raise RunnerError("runner SKU is unavailable or restricted")
    capabilities = {entry.get("name"): entry.get("value") for entry in item.get("capabilities", [])}
    if int(capabilities.get("vCPUsAvailable", "0")) < SKU_VCPUS[sku] or float(capabilities.get("MemoryGB", "0")) < SKU_MEMORY_GIB[sku]:
        raise RunnerError("runner SKU no longer satisfies the reviewed CPU/memory class")
    if capabilities.get("CpuArchitectureType") != "x64" or "V2" not in capabilities.get("HyperVGenerations", ""):
        raise RunnerError("runner SKU no longer satisfies x64 Gen2")


def runner_quota_snapshot(env, selected_skus):
    selected_skus = tuple(selected_skus)
    if not selected_skus or any(sku not in SKU_FAMILY for sku in selected_skus):
        raise RunnerError("runner quota snapshot requested an unreviewed SKU")
    skus, _, _ = az_command(env, ["vm", "list-skus", "--location", "eastus", "--resource-type", "virtualMachines", "--all"])
    if not isinstance(skus, list):
        raise RunnerError("runner SKU inventory is unreadable")
    for sku in selected_skus:
        matching = [item for item in skus if item.get("name") == sku]
        if len(matching) != 1:
            raise RunnerError("runner SKU is unavailable or ambiguous")
        validate_runner_sku_record(matching[0], sku)
    usage, _, _ = az_command(env, ["vm", "list-usage", "--location", "eastus"])
    if not isinstance(usage, list):
        raise RunnerError("runner quota usage is unreadable")
    wanted = {"cores"} | {SKU_FAMILY[sku].lower() for sku in selected_skus}
    matching_usage = {name: [] for name in wanted}
    for item in usage:
        name = str(item.get("name", {}).get("value", "")).lower()
        if name in matching_usage:
            matching_usage[name].append(item)
    if any(len(entries) != 1 for entries in matching_usage.values()):
        raise RunnerError("regional or exact runner-family quota identity is unavailable or ambiguous")
    quota = {}
    for name, entries in matching_usage.items():
        limit = int(entries[0].get("limit", 0))
        current = int(entries[0].get("currentValue", 0))
        if limit < 0 or current < 0 or current > limit:
            raise RunnerError("regional or exact runner-family quota values are invalid")
        quota[name] = {"limit": limit, "current": current, "free": limit - current}
    return {
        "regional": quota["cores"],
        "families": {sku: quota[SKU_FAMILY[sku].lower()] for sku in selected_skus},
    }


def sku_quota_gate(env, limits):
    snapshot = runner_quota_snapshot(env, (limits["sku"],))
    required = SKU_VCPUS[limits["sku"]]
    current_active = active_runner_vms(env)
    same_family_active = sum(
        1
        for vm in current_active
        if str((vm.get("tags") or {}).get("sku-family", "")).lower() == SKU_FAMILY[limits["sku"]].lower()
    )
    regional = snapshot["regional"]
    family = snapshot["families"][limits["sku"]]
    if regional["free"] < required or family["free"] < required:
        raise RunnerError("regional or exact runner-family free vCPU quota is insufficient")
    return {
        "regional_limit_vcpus": regional["limit"],
        "regional_free_vcpus": regional["free"],
        "family_limit_vcpus": family["limit"],
        "family_free_vcpus": family["free"],
        "family_active": same_family_active,
    }


def write_private_json(env, prefix, value):
    ensure_state_dirs(env)
    fd, name = tempfile.mkstemp(prefix=prefix, suffix=".json", dir=str(env["state_dir"]))
    os.chmod(name, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(value, handle, separators=(",", ":"))
        handle.write("\n")
    return Path(name)


SPEND_LEDGER_SCHEMA = "fm.azure-spend-ledger/v1"


@contextlib.contextmanager
def admission_lock(env):
    """Serialize local admission on this single-operator host."""
    ensure_state_dirs(env)
    lock_path = env["state_dir"] / ".admission.lock"
    with open(lock_path, "a+", encoding="utf-8") as handle:
        os.chmod(lock_path, 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def spend_ledger_path(env):
    return env["state_dir"] / "spend-ledger.json"


def read_spend_ledger(env):
    path = spend_ledger_path(env)
    try:
        ledger = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"schema": SPEND_LEDGER_SCHEMA, "entries": []}
    except (OSError, json.JSONDecodeError) as exc:
        raise RunnerError("local spend ledger is unreadable: {}".format(exc))
    if ledger.get("schema") != SPEND_LEDGER_SCHEMA or not isinstance(ledger.get("entries"), list):
        raise RunnerError("local spend ledger shape is invalid")
    return ledger


def spend_ledger_entry(env, invocation):
    for entry in read_spend_ledger(env)["entries"]:
        if entry.get("invocation") == invocation and entry.get("cleaned_at") is None:
            return entry
    return None


def spend_ledger_outstanding_entries(env, exclude_invocation=None):
    return [
        entry for entry in read_spend_ledger(env)["entries"]
        if entry.get("cleaned_at") is None
        and entry.get("invocation") != exclude_invocation
    ]


def spend_ledger_outstanding(env, exclude_invocation=None):
    return sum(
        float(entry.get("amount_usd", 0.0))
        for entry in spend_ledger_outstanding_entries(env, exclude_invocation)
    )


def spend_ledger_reserve(env, state, amount_usd):
    """Append one worst-case spend reservation for this invocation.

    Idempotent: an existing uncleaned entry for the invocation is kept as-is
    so a resumed dispatch never double-counts itself.
    """
    with state_lock(env):
        ledger = read_spend_ledger(env)
        for entry in ledger["entries"]:
            if entry.get("invocation") == state["invocation"] and entry.get("cleaned_at") is None:
                return entry
        entry = {
            "invocation": state["invocation"],
            "amount_usd": round(float(amount_usd), 6),
            "reserved_at": iso_utc(),
            "cleaned_at": None,
        }
        ledger["entries"].append(entry)
        save_private_json_atomic(spend_ledger_path(env), ledger)
        return entry


def spend_ledger_mark_cleaned(env, state):
    """Stamp the invocation's outstanding entry cleaned; idempotent."""
    with state_lock(env):
        ledger = read_spend_ledger(env)
        changed = False
        for entry in ledger["entries"]:
            if entry.get("invocation") == state["invocation"] and entry.get("cleaned_at") is None:
                entry["cleaned_at"] = iso_utc()
                changed = True
        if changed:
            save_private_json_atomic(spend_ledger_path(env), ledger)


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
    result = cost_http_query(env, endpoint, url, body)
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


def cost_cache_path(env):
    return env["state_dir"] / "cost-management-cache.json"


def load_cost_cache(env, cache_key, endpoint, body_digest):
    try:
        cache = json.loads(cost_cache_path(env).read_text(encoding="utf-8"))
        entry = cache["entries"][cache_key]
        fetched = dt.datetime.fromisoformat(entry["fetched_at"].replace("Z", "+00:00"))
        server = email.utils.parsedate_to_datetime(entry["server_date"])
    except (FileNotFoundError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
    if (
        cache.get("schema") != "fm.azure-cost-cache/v1"
        or cache.get("subscription") != env["subscription"]
        or cache.get("resource_group") != env["resource_group"]
        or entry.get("endpoint") != endpoint
        or entry.get("body_digest") != body_digest
        or server.tzinfo is None
        or fetched.tzinfo is None
    ):
        return None
    now = now_utc()
    if now < server or now - server > dt.timedelta(seconds=COST_CACHE_MAX_AGE_SECONDS):
        return None
    if now < fetched or now - fetched > dt.timedelta(seconds=COST_CACHE_MAX_AGE_SECONDS):
        return None
    return entry.get("result") if isinstance(entry.get("result"), dict) else None


def save_cost_cache(env, cache_key, endpoint, body_digest, server_date, result):
    path = cost_cache_path(env)
    with state_lock(env):
        try:
            cache = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            cache = {
                "schema": "fm.azure-cost-cache/v1",
                "subscription": env["subscription"],
                "resource_group": env["resource_group"],
                "entries": {},
            }
        except (OSError, json.JSONDecodeError) as exc:
            raise RunnerError("Cost Management cache is unreadable: {}".format(exc))
        if (
            cache.get("schema") != "fm.azure-cost-cache/v1"
            or cache.get("subscription") != env["subscription"]
            or cache.get("resource_group") != env["resource_group"]
            or not isinstance(cache.get("entries"), dict)
        ):
            raise RunnerError("Cost Management cache binding is not exact")
        cache["entries"][cache_key] = {
            "endpoint": endpoint,
            "body_digest": body_digest,
            "server_date": server_date,
            "fetched_at": iso_utc(),
            "result": result,
        }
        save_private_json_atomic(path, cache)


def retry_after_seconds(headers):
    for name in (
        "x-ms-ratelimit-microsoft.costmanagement-qpu-retry-after",
        "x-ms-ratelimit-microsoft.costmanagement-clienttype-retry-after",
        "x-ms-ratelimit-microsoft.consumption-retry-after",
        "Retry-After",
    ):
        raw = headers.get(name)
        if raw is None:
            continue
        try:
            return max(1, min(3600, int(raw)))
        except (TypeError, ValueError):
            try:
                when = email.utils.parsedate_to_datetime(raw)
                return max(1, min(3600, int((when - now_utc()).total_seconds())))
            except (TypeError, ValueError):
                continue
    return None


def cost_http_query(env, endpoint, url, body):
    body_bytes = canonical_bytes(body)
    body_digest = "sha256:" + sha256_bytes(body_bytes)
    cache_key = sha256_bytes((endpoint + "\0" + url + "\0" + body_digest).encode("utf-8"))
    deadline = time.monotonic() + COST_RETRY_DEADLINE_SECONDS
    while True:
        record_azure_operation(env, ["cost-management", endpoint])
        token_result = run([
            "az", "account", "get-access-token", "--subscription", env["subscription"],
            "--resource", "https://management.azure.com/", "--query", "accessToken",
            "--output", "tsv", "--only-show-errors",
        ], timeout_seconds=COST_QUERY_TIMEOUT_SECONDS)
        token = token_result.stdout.strip()
        if not token:
            raise RunnerError("Azure CLI returned no management token for Cost Management")
        request = urllib.request.Request(
            url, data=body_bytes, method="POST",
            headers={
                "Authorization": "Bearer " + token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
        )
        token = ""
        try:
            with urllib.request.urlopen(request, timeout=COST_QUERY_TIMEOUT_SECONDS) as response:
                server_date = response.headers.get("Date")
                if not server_date:
                    raise RunnerError("Cost Management success omitted its authoritative server date")
                try:
                    result = json.loads(response.read().decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise RunnerError("Cost Management returned malformed JSON: {}".format(exc))
                if not isinstance(result, dict):
                    raise RunnerError("Cost Management returned a non-object response")
                save_cost_cache(env, cache_key, endpoint, body_digest, server_date, result)
                return result
        except urllib.error.HTTPError as exc:
            if exc.code != 429:
                raise RunnerError("Cost Management {} failed with HTTP {}".format(endpoint, exc.code))
            cached = load_cost_cache(env, cache_key, endpoint, body_digest)
            wait_seconds = retry_after_seconds(exc.headers)
            remaining = deadline - time.monotonic()
            if wait_seconds is not None and wait_seconds <= remaining:
                time.sleep(wait_seconds)
                continue
            if cached is not None:
                return cached
            detail = "missing server retry guidance" if wait_seconds is None else "server retry exceeds bounded deadline"
            raise RunnerError(
                "Cost Management {} remained throttled with no exact authoritative cache ({})".format(endpoint, detail)
            )
        except urllib.error.URLError as exc:
            raise RunnerError("Cost Management {} transport failed closed: {}".format(endpoint, exc.reason))


RETAIL_RATE_CACHE_FRESH_SECONDS = 7 * 24 * 3600


def retail_rate(env, sku):
    """Resolve the SKU's hourly retail rate through a durable cache.

    The rate only feeds worst-case cost ceilings, so freshness is worth very
    little: prices.azure.com throttles bursts hard (generation 045 lost 21
    minutes to HTTP 429 backoff on a single dispatch), and a same-week cached
    ceiling bounds spend exactly as well. A fresh cache entry skips the API
    entirely; a stale entry is refreshed best-effort and still used verbatim
    when the API times out or throttles. Only a SKU with no cached rate at
    all requires the live read to succeed.
    """
    cache_path = env["state_dir"] / "retail-rate-cache.json"
    cache = {}
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
    except RunnerError as exc:
        if isinstance(entry, dict) and isinstance(entry.get("rate"), (int, float)) and entry["rate"] > 0:
            print(
                "azure-runner: retail rate API unavailable ({}); using cached ceiling for {}".format(
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
    result, _, _ = az_command(env, ["rest", "--method", "get", "--url", url, "--skip-authorization-header"])
    items = result.get("Items")
    sku_shape = re.fullmatch(r"Standard_([DE])\d+([a-z]+)_v(\d+)", sku)
    if not isinstance(items, list) or sku_shape is None:
        raise RunnerError("current runner retail rate response is unreadable")
    expected_meter = sku.removeprefix("Standard_").replace("_", " ")
    expected_product = "Virtual Machines {}{}v{} Series".format(
        sku_shape.group(1), sku_shape.group(2), sku_shape.group(3)
    )
    excluded_offers = ("spot", "low priority", "low-priority", "windows", "dev/test", "dev test", "reservation", "savings")
    prices = set()
    for item in items:
        if not isinstance(item, dict):
            continue
        offer = " ".join(str(item.get(field, "")) for field in (
            "productName", "meterName", "skuName", "type", "priceType", "reservationTerm",
        )).casefold()
        if any(excluded in offer for excluded in excluded_offers):
            continue
        if (
            str(item.get("armRegionName", "")).casefold() != "eastus"
            or item.get("armSkuName") != sku
            or str(item.get("serviceName", "")).casefold() != "virtual machines"
            or str(item.get("serviceFamily", "")).casefold() != "compute"
            or str(item.get("type", "")).casefold() != "consumption"
            or item.get("unitOfMeasure") != "1 Hour"
            or str(item.get("currencyCode", "")).upper() != "USD"
            or str(item.get("productName", "")).casefold() != expected_product.casefold()
            or str(item.get("skuName", "")).casefold() != expected_meter.casefold()
            or str(item.get("meterName", "")).casefold() != expected_meter.casefold()
            or item.get("isPrimaryMeterRegion") is not True
        ):
            continue
        try:
            price = float(item["retailPrice"])
            unit_price = float(item["unitPrice"])
            tier_minimum = float(item["tierMinimumUnits"])
        except (KeyError, TypeError, ValueError):
            continue
        if not math.isfinite(price) or price <= 0 or price != unit_price or tier_minimum != 0:
            continue
        prices.add(price)
    if not prices:
        raise RunnerError("exact Linux on-demand consumption retail rate is unreadable")
    if len(prices) != 1:
        raise RunnerError("exact Linux on-demand consumption retail rate is ambiguous")
    return prices.pop()


def itemized_cost_bound(rate, hours, limits, parent_managed=False):
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
        "foundation_shared_meter_reserve": 0.0 if parent_managed else FOUNDATION_SHARED_METER_RESERVE_USD,
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


def budget_gate(env, limits, outstanding_reservations=0.0, parent_managed=False):
    actual = cost_query(env, forecast=False)
    try:
        forecast = cost_query(env, forecast=True)
    except RunnerError as exc:
        # A young subscription has no cost training data and the forecast
        # endpoint fails with HTTP 424 until it trains. Commissioning-bounded
        # admission substitutes the readable actual as the forecast, mirroring
        # the worker lifecycle's released commissioning seam. Strict admission
        # accepts the same substitution only under the operator's explicit
        # FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST=1 confirmation (the one
        # knob the lifecycle already honors), because validation shards run
        # strict under a capacity parent on the same untrained subscription;
        # any other unreadable cost state still refuses.
        untrained = "failed with HTTP 424" in str(exc)
        throttled = "remained throttled with no exact authoritative cache" in str(exc)
        allowed = os.environ.get("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST") == "1"
        if untrained and (
            env.get("cost_admission_mode") == COMMISSIONING_COST_ADMISSION_MODE
            or allowed
        ):
            forecast = actual
        elif throttled and allowed:
            # The knob asserts the forecast endpoint is untrained, so a
            # throttled forecast (concurrent shards share one zero-quota
            # Cost Management bucket) could at best return the same 424;
            # the readable actual substitutes here too, while the actual
            # query itself still fails closed on any error.
            forecast = actual
        else:
            raise
    rate = retail_rate(env, limits["sku"])
    first_hour = itemized_cost_bound(rate, 1, limits, parent_managed=parent_managed)
    first_day = itemized_cost_bound(
        rate, MAX_BILLABLE_LIFETIME_HOURS, limits, parent_managed=parent_managed
    )
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
        "cost_admission_mode": STRICT_COST_ADMISSION_MODE,
    }


def exact_commissioning_budget(env):
    budget_name = "bud-{}-monthly".format(env["prefix"])
    budget_id = "/subscriptions/{}/providers/Microsoft.Consumption/budgets/{}".format(
        env["subscription"], budget_name
    )
    budget, _, _ = az_command(env, [
        "rest", "--method", "get", "--url",
        "https://management.azure.com{}?api-version=2024-08-01".format(budget_id),
    ])
    properties = budget.get("properties", budget)
    exact_filter = {
        "dimensions": {
            "name": "ResourceGroupName", "operator": "In", "values": [env["resource_group"]],
        }
    }
    expected_notifications = {
        "actual750": (50, "Actual"), "actual1000": (66.67, "Actual"),
        "actual1250": (83.33, "Actual"), "actual1500": (100, "Actual"),
        "forecast750": (50, "Forecasted"), "forecast1000": (66.67, "Forecasted"),
        "forecast1250": (83.33, "Forecasted"), "forecast1500": (100, "Forecasted"),
    }
    notifications = {
        str(name).lower(): value for name, value in (properties.get("notifications") or {}).items()
    }
    notifications_exact = set(notifications) == set(expected_notifications)
    if notifications_exact:
        for name, (threshold, threshold_type) in expected_notifications.items():
            value = notifications[name]
            if (
                value.get("enabled") is not True
                or value.get("operator") != "GreaterThanOrEqualTo"
                or float(value.get("threshold", -1)) != threshold
                or value.get("thresholdType") != threshold_type
                or len(value.get("contactEmails") or []) != 1
            ):
                notifications_exact = False
                break
    if (
        str(budget.get("id", "")).lower() != budget_id.lower()
        or budget.get("name") != budget_name
        or budget.get("type") != "Microsoft.Consumption/budgets"
        or properties.get("category") != "Cost"
        or float(properties.get("amount", -1)) != 1500.0
        or properties.get("timeGrain") != "Monthly"
        or properties.get("filter") != exact_filter
        or not notifications_exact
        or not (budget.get("eTag") or budget.get("etag"))
    ):
        raise RunnerError("commissioning budget identity/amount/filter/alerts are not exact")
    return {"id": budget_id, "etag": budget.get("eTag") or budget.get("etag")}


def commissioning_cost_gate(env, state, limits):
    """Wallet-only commissioning admission over the local spend ledger.

    Keeps the exact $1500 Monthly budget-with-alerts proof and the itemized
    worst-case bound; capacity spreading stays owned by the deterministic
    cell-ordinal SKU pool selection at prepare time.
    """
    if not 1 <= env["max_concurrency"] <= 16 or env["budget_limit"] != 1500:
        raise RunnerError("commissioning-bounded requires configured concurrency 1..16 and the exact $1500 alert budget")
    if limits != state.get("request", {}).get("limits"):
        raise RunnerError("commissioning cost limits differ from the exact prepared capacity slot")
    exact_commissioning_budget(env)
    rate = retail_rate(env, limits["sku"])
    # A shard under a validation capacity parent omits the shared foundation
    # share the parent already reserved, exactly as the strict budget gate
    # does.
    parent_managed = bool(state.get("request", {}).get("capacity_parent"))
    first_hour = itemized_cost_bound(rate, 1, limits, parent_managed=parent_managed)
    first_day = itemized_cost_bound(rate, MAX_BILLABLE_LIFETIME_HOURS, limits, parent_managed=parent_managed)
    if not 0 < first_day["total"] < float("inf"):
        raise RunnerError("commissioning-bounded full 24-hour itemized maximum is not finite and positive")
    outstanding_entries = spend_ledger_outstanding_entries(env, exclude_invocation=state["invocation"])
    reserved_total = sum(entry["amount_usd"] for entry in outstanding_entries)
    current_reserved = spend_ledger_entry(env, state["invocation"]) is not None
    occupied = len(outstanding_entries) + (1 if current_reserved else 0)
    if occupied > env["max_concurrency"] or (not current_reserved and occupied >= env["max_concurrency"]):
        raise RunnerError("commissioning runner queue is at its bounded concurrency limit ({})".format(env["max_concurrency"]))
    active = active_runner_vms(env)
    return {
        "actual": None,
        "forecast": None,
        "hourly_rate": rate,
        "first_hour": first_hour,
        "first_day": first_day,
        "max_network_bytes": limits["network_bytes"],
        "max_billable_lifetime_hours": MAX_BILLABLE_LIFETIME_HOURS,
        "max_increment": first_day["total"],
        "outstanding_reservations": reserved_total,
        "reserved_invocations": occupied,
        "active_runner_vms": len(active),
        "admission_pressure": None,
        "cost_admission_mode": COMMISSIONING_COST_ADMISSION_MODE,
    }


def shared_capacity_role(state):
    resource_class = state["request"].get("resource_class")
    if resource_class == "crosscheck-tool":
        return "crosscheck"
    return "validation"


def shared_capacity_environment(env):
    command_env = dict(os.environ)
    # The allocator store is fenced to its home identity, so the operator's
    # exported FM_HOME must win when the runner executes from a different
    # checkout; the script root is only the fallback, and the state dir
    # defaults beside whichever home is declared.
    command_env.setdefault("FM_HOME", str(ROOT))
    command_env["FM_AZURE_WORKER_STATE_DIR"] = str(
        Path(os.environ.get(
            "FM_AZURE_SHARED_CAPACITY_STATE_DIR",
            str(Path(command_env["FM_HOME"]) / "state" / "azure-workers"),
        )).resolve()
    )
    if env["budget_limit"] == 1500:
        command_env["FM_AZURE_WORKER_POLICY_PHASE"] = "commissioning"
        command_env["FM_AZURE_WORKER_COMMISSIONING_CEILING_USD"] = "1500"
    else:
        command_env["FM_AZURE_WORKER_POLICY_PHASE"] = "steady"
        command_env["FM_AZURE_WORKER_STEADY_TARGET_USD"] = str(env["budget_limit"])
    return command_env


def shared_capacity_reserve(env, state, cost):
    request = state["request"]
    limits = request["limits"]
    fence = request.get("capacity_fence") or request["fence"].split(":", 1)[1]
    command = [
        sys.executable, str(WORKER_LIFECYCLE), "capacity-reserve",
        "--reservation-id", state["invocation"],
        "--fence-binding", fence,
        "--role", shared_capacity_role(state),
        "--sku", limits["sku"],
        "--sku-family", limits["sku_family"],
        "--vcpus", str(SKU_VCPUS[limits["sku"]]),
        "--amount-usd", str(cost["max_increment"]),
        "--confirm-subscription", env["subscription"],
    ]
    previous = state.get("shared_capacity_reservation", {})
    wait_deadline_text = previous.get("wait_deadline")
    if wait_deadline_text:
        try:
            wait_deadline = dt.datetime.fromisoformat(
                wait_deadline_text.replace("Z", "+00:00")
            )
            if wait_deadline.utcoffset() is None:
                raise ValueError("capacity wait deadline has no timezone")
        except (TypeError, ValueError):
            if previous.get("status") == "queued":
                shared_capacity_release(env, state)
            raise RunnerError("shared allocator capacity wait deadline is malformed")
    else:
        wait_deadline = now_utc() + dt.timedelta(
            seconds=env["capacity_wait_seconds"]
        )
        wait_deadline_text = iso_utc(wait_deadline)
    monotonic_deadline = time.monotonic() + max(
        0.0, (wait_deadline - now_utc()).total_seconds()
    )
    last_reason = "capacity unavailable"
    while True:
        try:
            result = run(command, env=shared_capacity_environment(env))
        except RunnerError:
            if state.get("shared_capacity_reservation", {}).get("status") == "queued":
                shared_capacity_release(env, state)
            raise
        try:
            reservation = json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError):
            if state.get("shared_capacity_reservation", {}).get("status") == "queued":
                shared_capacity_release(env, state)
            raise RunnerError("shared allocator returned a malformed capacity reservation")
        if (
            not isinstance(reservation, dict)
            or reservation.get("reservation_id") != state["invocation"]
            or reservation.get("status") not in ("queued", "reserved")
        ):
            if state.get("shared_capacity_reservation", {}).get("status") == "queued":
                shared_capacity_release(env, state)
            raise RunnerError("shared allocator returned a reservation with the wrong identity")
        previous = state.get("shared_capacity_reservation", {})
        last_reason = str(reservation.get("reason") or "capacity unavailable")[:500]
        state["shared_capacity_reservation"] = {
            "reservation_id": state["invocation"],
            "fence_binding": fence,
            "status": reservation["status"],
            "amount_usd": cost["max_increment"],
            "sku": limits["sku"],
            "sku_family": limits["sku_family"],
            "actual_usd": reservation.get("actual_usd"),
            "forecast_usd": reservation.get("forecast_usd"),
            "admission_limit_usd": reservation.get("admission_limit_usd"),
            "reason": last_reason if reservation["status"] == "queued" else "",
            "wait_deadline": wait_deadline_text,
            "queued_at": previous.get("queued_at") or (
                iso_utc() if reservation["status"] == "queued" else None
            ),
        }
        save_state(env, state)
        if reservation["status"] == "reserved":
            break
        if last_reason not in TRANSIENT_SHARED_CAPACITY_REFUSALS:
            shared_capacity_release(env, state)
            raise RunnerError(
                "shared allocator queued disposable-runner demand: {}".format(
                    last_reason
                )
            )
        remaining = min(
            monotonic_deadline - time.monotonic(),
            (wait_deadline - now_utc()).total_seconds(),
        )
        if remaining <= 0:
            shared_capacity_release(env, state)
            raise RunnerError(
                "shared allocator capacity wait timed out after {} seconds: {}".format(
                    env["capacity_wait_seconds"], last_reason
                )
            )
        time.sleep(min(env["capacity_poll_seconds"], remaining))
    try:
        cost["actual"] = reservation.get("actual_usd")
        cost["forecast"] = reservation.get("forecast_usd")
        cost["shared_admission_limit"] = reservation.get("admission_limit_usd")
        if not isinstance(cost["actual"], (int, float)) or not isinstance(cost["forecast"], (int, float)):
            raise RunnerError("shared allocator omitted readable actual or forecast spend evidence")
        if max(float(cost["actual"]), float(cost["forecast"])) + float(cost["max_increment"]) >= env["budget_limit"]:
            raise RunnerError("shared actual/forecast cost pressure reaches the runner admission limit")
    except RunnerError as exc:
        try:
            shared_capacity_release(env, state)
        except RunnerError as release_exc:
            raise RunnerError(
                "{}; shared capacity release also failed: {}".format(
                    exc, release_exc
                )
            ) from release_exc
        raise
    return cost


def shared_capacity_release(env, state):
    reservation = state.get("shared_capacity_reservation")
    if not reservation or reservation.get("status") == "released":
        return
    fence = state["request"].get("capacity_fence") or state["request"]["fence"].split(":", 1)[1]
    receipt = sha256_bytes(canonical_bytes({
        "invocation": state["invocation"],
        "fence": state["request"]["fence"],
        "resources": state.get("resources"),
        "compute_absent_phase": state.get("phase"),
    }))
    run([
        sys.executable, str(WORKER_LIFECYCLE), "capacity-release",
        "--reservation-id", state["invocation"],
        "--fence-binding", fence,
        "--cleanup-receipt", receipt,
        "--confirm-subscription", env["subscription"],
    ], env=shared_capacity_environment(env))
    reservation["status"] = "released"
    reservation["cleanup_receipt"] = receipt
    save_state(env, state)


def runner_control_id(env):
    return (
        "/subscriptions/{}/resourceGroups/{}/providers/Microsoft.Storage/storageAccounts/{}"
        "/blobServices/default/containers/{}"
    ).format(env["subscription"], env["resource_group"], env["control_storage"], CONTROL_CONTAINER)


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


def validation_capacity_parent_gate(env, state):
    parent = state["request"].get("capacity_parent")
    if not parent:
        return
    reservation = int(state["request"]["capacity_reservation_vcpus"])
    vms, _, _ = az_command(env, [
        "vm", "list", "--resource-group", env["resource_group"], "--show-details",
    ])
    parents = []
    child_count = 0
    for vm in vms:
        tags = vm.get("tags") or {}
        if "deallocated" in str(vm.get("powerState", "")).lower():
            continue
        if tags.get("firstmate-role") == "validation-cell" and tags.get("validation-cell") == parent:
            parents.append(vm)
        if tags.get("firstmate-role") == "validation-shard" and tags.get("capacity-parent") == parent:
            child_count += 1
    if len(parents) != 1:
        raise RunnerError("capacity parent cell is absent, deallocated, or ambiguous")
    tags = parents[0].get("tags") or {}
    expected = {
        "workload": "firstmate",
        "firstmate-role": "validation-cell",
        "lifecycle": "elastic-scale-to-zero",
        "deployment-generation": env["deployment_generation"],
        "cleanup-owner": env["owner"],
        "home-binding": state["request"]["home_binding"],
        "validation-cell": parent,
        "reserved-vcpus": str(reservation),
    }
    if any(tags.get(key) != value for key, value in expected.items()):
        raise RunnerError("capacity parent owner/generation/home/reservation identity is not exact")
    if child_count >= max(0, (reservation - 8) // 4):
        raise RunnerError("capacity parent has no reserved processor slot for another shard")


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
        "capacity-parent": request.get("capacity_parent") or "none",
        "capacity-reservation-vcpus": str(request.get("capacity_reservation_vcpus") or 0),
        "invocation-binding": state["invocation"],
        "attempt": str(state["attempt"]),
        "fence": request["fence"],
        "snapshot-digest": request["repository"]["snapshot_digest"],
        "command-digest": request["command_digest"],
        "resource-class": request["resource_class"],
        "selected-sku": request["limits"]["sku"],
        "sku-family": request["limits"]["sku_family"],
        "cell-ordinal": str(request.get("cell_ordinal") or "none"),
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
            "controllerIdentityId": {"value": exact_id(env, "Microsoft.ManagedIdentity", "userAssignedIdentities", env["controller_identity"])},
            "vmSize": {"value": request["limits"]["sku"]},
            "expiryUtc": {"value": iso_utc(expiry)},
            "expiryTimeOfDay": {"value": expiry.strftime("%H%M")},
            "tags": {"value": tags},
            # Optional golden image: an empty value keeps the marketplace
            # base; the guests re-verify every staged archive digest at
            # boot either way, so the image only caches the bootstrap.
            "imageId": {"value": os.environ.get("FM_AZURE_VM_IMAGE_ID", "")},
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
        # Managed-disk GETs return no body etag at any current API version;
        # the immutable uniqueId substitutes, matching the validation
        # controller's disk identity contract.
        identity["etag"] = identity["etag"] or identity["unique_id"]
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
    # Run commands and DevTestLab schedules return no body etag on GET,
    # exactly as the validation controller's identity contract records;
    # their stable field plus the exact id carry the identity.
    if (
        not identity["id"]
        or (label not in ("run-command", "ttl-schedule") and not identity["etag"])
        or not identity.get(required)
    ):
        raise RunnerError("created {} immutable identity is incomplete".format(label))
    return identity


def adopt_vm_identity(env, state, vm):
    resources = state["resources"]
    vm_id = vm.get("id")
    vm_properties = vm.get("properties", vm)
    instance_id = vm_properties.get("vmId")
    nic_ids = [item.get("id") for item in vm_properties.get("networkProfile", {}).get("networkInterfaces", [])]
    os_disk_id = vm_properties.get("storageProfile", {}).get("osDisk", {}).get("managedDisk", {}).get("id")
    expected_identity_id = exact_id(env, "Microsoft.ManagedIdentity", "userAssignedIdentities", env["controller_identity"])
    assigned_identities = list((vm.get("identity") or vm_properties.get("identity") or {}).get("userAssignedIdentities", {}))
    if (
        not vm_id
        or not instance_id
        or len(nic_ids) != 1
        or vm_id.lower() != resources["vm_id"].lower()
        or nic_ids[0].lower() != resources["nic_id"].lower()
        or str(os_disk_id).lower() != resources["os_disk_id"].lower()
        or [item.lower() for item in assigned_identities] != [expected_identity_id.lower()]
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


def require_compute_deallocation_lead(state):
    deadline = dt.datetime.fromisoformat(
        state["request"]["compute_deallocation_deadline"].replace("Z", "+00:00")
    )
    required_lead = dt.timedelta(
        seconds=AZURE_SCHEDULE_MINIMUM_LEAD_SECONDS + DEPLOYMENT_TIMEOUT_SECONDS
    )
    if deadline <= now_utc() + required_lead:
        raise RunnerError(
            "control-plane TTL schedule has insufficient lead for Azure's 30-minute activation window and bounded deployment"
        )


def create_vm(env, state):
    require_compute_deallocation_lead(state)
    params = write_private_json(env, ".vm-params-", deployment_parameters(env, state))
    try:
        az_command(env, [
            "deployment", "group", "create", "--resource-group", env["resource_group"],
            "--name", state["resources"]["deployment"], "--template-file", str(TEMPLATE),
            "--parameters", "@" + str(params), "--mode", "Incremental",
        ], timeout_seconds=DEPLOYMENT_TIMEOUT_SECONDS)
    finally:
        params.unlink(missing_ok=True)
    exists, vm = read_exact_resource(env, state["resources"]["vm_id"], "vm")
    if not exists:
        raise RunnerError("runner deployment completed without its exact VM")
    adopt_vm_identity(env, state, vm)
    transition(env, state, "vm-created", "exact private controller VM/UAMI/NIC/OS disk created")


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


def private_snapshot_record(env, state):
    blob = state["staging"].get("input_blob")
    if not blob:
        return None
    value, rc, stderr = az_command(env, [
        "storage", "blob", "show", "--auth-mode", "login",
        "--account-name", env["storage"], "--container-name", CONTAINER,
        "--name", blob,
    ], check=False)
    if rc != 0:
        exists, exists_rc, exists_stderr = az_command(env, [
            "storage", "blob", "exists", "--auth-mode", "login",
            "--account-name", env["storage"], "--container-name", CONTAINER,
            "--name", blob,
        ], check=False)
        if exists_rc != 0:
            raise RunnerError("private snapshot existence is ambiguous: {}; {}".format(stderr, exists_stderr))
        if not exists.get("exists"):
            return None
        raise RunnerError("private snapshot exists but its exact identity is unreadable")
    return value


def verify_private_snapshot_record(state, value):
    repository = state["request"]["repository"]
    properties = value.get("properties", value)
    metadata = value.get("metadata") or properties.get("metadata") or {}
    etag = value.get("etag") or properties.get("etag")
    if (
        not etag
        or int(properties.get("contentLength", value.get("contentLength", -1))) != repository["snapshot_bytes"]
        or metadata != {
            "snapshotdigest": repository["snapshot_digest"].split(":", 1)[1],
            "commit": repository["commit"],
        }
    ):
        raise RunnerError("private snapshot blob size/digest/commit identity is not exact")
    return etag


def stage_private_snapshot(env, state):
    blob = state["staging"].get("input_blob")
    if not blob:
        return
    existing = private_snapshot_record(env, state)
    if existing is not None:
        state["staging"]["input_blob_etag"] = verify_private_snapshot_record(state, existing)
        save_state(env, state)
        return
    source = Path(state["input_path"]).parent / "snapshot.bundle"
    repository = state["request"]["repository"]
    if (
        not source.is_file()
        or "sha256:" + sha256_file(source) != repository["snapshot_digest"]
        or source.stat().st_size != repository["snapshot_bytes"]
    ):
        raise RunnerError("private snapshot payload differs from its request binding")
    az_command(env, [
        "storage", "blob", "upload", "--auth-mode", "login",
        "--account-name", env["storage"], "--container-name", CONTAINER,
        "--name", blob, "--file", str(source), "--overwrite", "false",
        "--metadata",
        "snapshotdigest={}".format(repository["snapshot_digest"].split(":", 1)[1]),
        "commit={}".format(repository["commit"]),
    ])
    created = private_snapshot_record(env, state)
    if created is None:
        raise RunnerError("private snapshot upload completed without its exact blob")
    state["staging"]["input_blob_etag"] = verify_private_snapshot_record(state, created)
    save_state(env, state)


def delete_private_snapshot(env, state):
    blob = state["staging"].get("input_blob")
    if not blob:
        return
    value = private_snapshot_record(env, state)
    if value is None:
        return
    etag = verify_private_snapshot_record(state, value)
    if state["staging"].get("input_blob_etag") != etag:
        raise RunnerError("private snapshot blob ETag changed; cleanup retained")
    _, rc, stderr = az_command(env, [
        "storage", "blob", "delete", "--auth-mode", "login",
        "--account-name", env["storage"], "--container-name", CONTAINER,
        "--name", blob, "--if-match", etag,
    ], check=False)
    if rc != 0:
        raise RunnerError("private snapshot conditional delete failed: {}".format(stderr))
    if private_snapshot_record(env, state) is not None:
        raise RunnerError("private snapshot remains after exact deletion")


def create_run_command(env, state):
    current_guest_digest = "sha256:" + sha256_file(GUEST)
    if current_guest_digest != state["request"]["protocol"]["guest_digest"]:
        raise RunnerError("trusted guest protocol changed after request preparation")
    current_installer_digest = "sha256:" + sha256_file(AGENT_FLEET_INSTALLER)
    if current_installer_digest != state["request"]["protocol"]["agent_fleet_installer_digest"]:
        raise RunnerError("trusted Agent Fleet installer changed after request preparation")
    script = GUEST.read_text(encoding="utf-8")
    request_b64 = base64.b64encode(Path(state["input_path"]).read_bytes()).decode("ascii")
    executor_b64 = base64.b64encode(EXECUTOR.read_bytes()).decode("ascii")
    agent_fleet_installer_b64 = base64.b64encode(AGENT_FLEET_INSTALLER.read_bytes()).decode("ascii")
    properties = {
        "location": "eastus",
        "tags": ownership_tags(env, state),
        "properties": {
            "source": {"script": script},
            "parameters": [
                {"name": "request_b64", "value": request_b64},
                {"name": "vm_resource_id", "value": state["resources"]["vm_id"]},
                {"name": "vm_instance_id", "value": state["resources"]["vm_instance_id"]},
                {"name": "guest_digest", "value": state["request"]["protocol"]["guest_digest"]},
                {"name": "storage_account", "value": env["storage"]},
                {"name": "container", "value": CONTAINER},
                {"name": "output_blob", "value": state["staging"]["output_blob"]},
                {"name": "input_blob", "value": state["staging"].get("input_blob") or "none"},
                {"name": "identity_client_id", "value": env["controller_identity_client_id"]},
                {"name": "executor_b64", "value": executor_b64},
                {"name": "agent_fleet_installer_b64", "value": agent_fleet_installer_b64},
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
                # An unstructured guest death (bootstrap failure, OOM, eviction)
                # used to raise here and leave a live VM holding an ambiguous
                # non-result forever: retry demands proven absence, and nothing
                # deleted the VM (generation 044 deadlock). Record the failure
                # durably and tear the disposable compute down in this same
                # call so the next pass can fence and retry without an
                # operator sweep.
                transition(env, state, "failed-retained", "managed run command failed ({}, {}): {}".format(execution, provisioning, error[-500:]))
                teardown_failed_compute(env, state)
                raise RunnerError("guest died without a structured result ({}); compute removed so the retry lane can fence: {}".format(execution, error[-500:]))
            marker = re.search(r"FM_AZURE_RESULT\s+(sha256:[0-9a-f]{64})\s+boot=([0-9a-f-]{36})\s+result=([A-Za-z0-9+/=]+)", output)
            if not marker:
                raise RunnerError("managed run command completed without a valid result identity marker")
            state["expected_result_digest"] = marker.group(1)
            state["expected_boot_id"] = marker.group(2)
            try:
                state["control_plane_result"] = json.loads(base64.b64decode(marker.group(3), validate=True))
            except (ValueError, json.JSONDecodeError) as exc:
                raise RunnerError("managed run command returned malformed bounded result: {}".format(exc))
            transition(env, state, "result-published", "guest published digest-bound output")
            return
        time.sleep(10)
    raise RunnerError("managed run command exceeded its control-plane completion bound")



def collect_result(env, state):
    result_dir = env["state_dir"] / "results" / state["invocation"]
    if result_dir.exists():
        raise RunnerError("result destination already exists; collection will not overwrite it")
    result = state.get("control_plane_result")
    if not isinstance(result, dict):
        raise RunnerError("bounded control-plane result is absent")
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
            raise RunnerError("bounded result identity mismatch: {}".format(key))
    if not isinstance(result.get("artifacts"), list):
        raise RunnerError("bounded result artifact manifest is malformed")
    result_dir.mkdir(parents=True, mode=0o700)
    result_path = result_dir / "result.json"
    result_path.write_bytes(canonical_bytes(result) + b"\n")
    os.chmod(result_path, 0o600)
    state["result"] = result
    state["result_path"] = str(result_dir)
    state["result_digest"] = state["expected_result_digest"]
    transition(env, state, "result-collected", "result identity and every returned digest verified")
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
        "home-binding", "task-binding", "task-generation", "capacity-parent", "capacity-reservation-vcpus", "invocation-binding", "attempt", "fence",
        "snapshot-digest", "command-digest", "resource-class", "selected-sku", "sku-family",
        "cell-ordinal", "cost-attribution", "cleanup-token",
    ):
        if tags.get(key) != expected[key]:
            raise RunnerError("live {} cleanup tag mismatch: {}".format(label, key))


def verify_live_resource_identity(env, state, kind, resource_id, identity_key=None, require_vm_relation=True, stable_only=False):
    exists, resource = read_exact_resource(env, resource_id, kind)
    if not exists:
        return False, None
    verify_resource_tags(env, state, resource, kind)
    identity_key = identity_key or kind
    recorded = state["resources"].get("identities", {}).get(identity_key)
    live = immutable_identity(resource, kind)
    if recorded is None:
        if kind == "run-command":
            # The resume adopt lane ("existing Managed Run Command adopted
            # without resubmission") can own a run command whose creating
            # pass was interrupted between creation and identity recording;
            # its ownership tags were verified above, and its exact id plus
            # those tags carry its whole identity, so adopt-and-log instead
            # of refusing cleanup forever (generation 044 ground truth).
            state["resources"].setdefault("identities", {})[identity_key] = live
            save_state(env, state)
            recorded = live
        else:
            raise RunnerError("live {} immutable identity changed; cleanup retained ambiguous state".format(kind))
    if kind == "run-command":
        # Execution mutates a run command's etag and provisioning state, so
        # the exact resource id plus the verified ownership tags carry its
        # whole identity.
        if live["id"] != recorded["id"]:
            raise RunnerError("live {} immutable identity changed; cleanup retained ambiguous state".format(kind))
    elif stable_only:
        # Deleting the VM mutates every dependent resource's etag, so the
        # absence fence compares the stable immutable field and exact id
        # instead of the full creation-time identity.
        if kind == "run-command":
            # A run command's provisioning state legitimately transitions when
            # it executes - including the wallet's safety-shutdown sibling
            # firing on its own schedule - so it can never serve as a stable
            # identity field: doing so deadlocked cleanup behind a deterministic
            # refusal once the wallet fired (generation 041/044 ground truth).
            # The exact resource id plus verified ownership tags carry the
            # whole identity, matching the non-stable run-command rule above.
            if live["id"] != recorded["id"]:
                raise RunnerError("live {} immutable identity changed; cleanup retained ambiguous state".format(kind))
        else:
            stable_field = {
                "vm": "instance_id", "nic": "resource_guid", "disk": "unique_id",
                "ttl-schedule": "task_type",
            }[kind]
            if live["id"] != recorded["id"] or live.get(stable_field) != recorded.get(stable_field):
                raise RunnerError("live {} immutable identity changed; cleanup retained ambiguous state".format(kind))
    elif live != recorded:
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
        exists, resource = verify_live_resource_identity(
            env, state, kind, resource_id, identity_key,
            require_vm_relation=False, stable_only=True,
        )
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
    arguments = ["rest", "--method", "delete", "--url", url]
    if resource.get("etag"):
        arguments += ["--headers", "If-Match={}".format(resource["etag"])]
    _, rc, stderr = az_command(env, arguments, check=False)
    if rc != 0:
        raise RunnerError("conditional exact {} deletion failed: {}".format(kind, stderr))
    # ARM deletions are asynchronous: a half-deleted resource can keep
    # listing while its GET already fails, so absence is proven by a
    # bounded poll rather than one immediate read-back.
    deadline = time.monotonic() + 90
    while True:
        try:
            remains, _ = read_exact_resource(env, resource_id, kind)
        except RunnerError:
            remains = True
        if not remains:
            return
        if time.monotonic() >= deadline:
            raise RunnerError("exact {} still exists after conditional delete".format(kind))
        time.sleep(5)


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


def teardown_failed_compute(env, state):
    """Remove a dead guest's disposable compute so absence can be proven.

    Reached only from a durably recorded terminal run-command failure with no
    result to protect. Deletes the same disposable set as cleanup (run
    commands, VM, NIC, OS disk, TTL schedule) under the same identity
    verification; durable snapshot/staging state is untouched. A refusal
    leaves the phase failed-retained, and the next resume converges by
    re-entering this teardown.
    """
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


def cleanup(env, state):
    if state.get("phase") not in ("result-collected", "cleanup-retained", "compute-removed", "complete"):
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
        delete_private_snapshot(env, state)
    except RunnerError:
        transition(env, state, "cleanup-retained", "private snapshot cleanup is ambiguous")
        raise
    payload_dir = Path(state["input_path"]).parent
    if payload_dir.parent == env["state_dir"] / "payloads":
        # A repeated cleanup can race an earlier partial removal; an already
        # absent tree is exactly the desired end state.
        try:
            shutil.rmtree(payload_dir, ignore_errors=False)
        except FileNotFoundError:
            pass
    if state.get("reservation_recorded"):
        spend_ledger_mark_cleaned(env, state)
    try:
        shared_capacity_release(env, state)
    except RunnerError:
        transition(env, state, "cleanup-retained", "shared capacity reservation release is ambiguous")
        raise
    transition(env, state, "complete", "verified bounded result retained locally; private result archive retained; invocation compute is zero")


def dispatch_prepared(env, state, confirm_subscription, confirm_cost_admission_mode=None):
    bind_operation_context(env, state)
    if confirm_subscription != env["subscription"]:
        raise RunnerError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    mode = state["request"].get("cost_admission_mode", STRICT_COST_ADMISSION_MODE)
    if mode != env["cost_admission_mode"]:
        raise RunnerError("prepared cost admission mode differs from current operator configuration")
    if mode == COMMISSIONING_COST_ADMISSION_MODE:
        if confirm_cost_admission_mode != COMMISSIONING_COST_ADMISSION_MODE:
            raise RunnerError("commissioning-bounded requires --confirm-cost-admission-mode commissioning-bounded")
        if env.get("cell_ordinal") != state["request"].get("cell_ordinal"):
            raise RunnerError("current commissioning cell ordinal differs from the exact prepared request")
        configured_sku = os.environ.get("FM_AZURE_RUNNER_SKU")
        if configured_sku is not None and configured_sku != state["request"].get("limits", {}).get("sku"):
            raise RunnerError("current commissioning SKU override differs from the exact prepared request")
    elif confirm_cost_admission_mode is not None:
        raise RunnerError("--confirm-cost-admission-mode is accepted only for commissioning-bounded")
    elif env.get("cell_ordinal") is not None:
        raise RunnerError("FM_AZURE_RUNNER_CELL_ORDINAL is accepted only for commissioning-bounded")
    compute_create_attempted = False
    try:
        deadline = dt.datetime.fromisoformat(
            state["request"]["compute_deallocation_deadline"].replace("Z", "+00:00")
        )
        if deadline <= now_utc() + dt.timedelta(minutes=10):
            raise RunnerError("prepared invocation has insufficient time remaining before its control-plane deallocation deadline")
        scope_gate(env)
        limits = state["request"]["limits"]
        validation_capacity_parent_gate(env, state)
        cost = (
            commissioning_cost_gate(env, state, limits)
            if mode == COMMISSIONING_COST_ADMISSION_MODE
            else budget_gate(
                env, limits,
                outstanding_reservations=spend_ledger_outstanding(
                    env, exclude_invocation=state["invocation"]
                ),
                parent_managed=bool(state["request"].get("capacity_parent")),
            )
        )
        foundation_gate(env)
        cost = shared_capacity_reserve(env, state, cost)
        transition(
            env, state, "admission-checked",
            "scope, SKU, exact foundation, and shared regional/family/actual-forecast cost admission passed",
            cost=cost,
        )
        # Read-only proofs and per-invocation staging need no shared-state
        # protection, so they run before the lock: concurrent shard
        # transports previously serialized their multi-minute snapshot
        # uploads and GitHub re-proofs behind one holder, and generation
        # 052's fourth transport timed out waiting on exactly that.
        reprove_public_request(state)
        stage_private_snapshot(env, state)
        with admission_lock(env):
            active = active_runner_vms(env)
            if len(active) >= env["max_concurrency"]:
                raise RunnerError("runner queue is at its bounded concurrency limit ({})".format(env["max_concurrency"]))
            spend_ledger_reserve(env, state, cost["max_increment"])
            transition(
                env, state, "cost-reserved",
                "worst-case cost recorded in the local spend ledger",
                cost=cost, reservation_recorded=True,
            )
            if mode == COMMISSIONING_COST_ADMISSION_MODE:
                commissioning_cost_gate(env, state, limits)
            sku_quota_gate(env, limits)
            foundation_gate(env)
            validation_capacity_parent_gate(env, state)
        # The ledger entry recorded above is the durable spend claim; VM
        # creation only materializes it, so concurrent transports create
        # their compute in parallel instead of holding the admission lock
        # through a multi-minute control-plane operation.
        require_compute_deallocation_lead(state)
        compute_create_attempted = True
        create_vm(env, state)
        create_run_command(env, state)
        poll_run_command(env, state)
        result = collect_result(env, state)
        cleanup(env, state)
    except Exception as exc:
        if (
            not compute_create_attempted
            and state.get("shared_capacity_reservation", {}).get("status")
            in ("queued", "reserved")
        ):
            if state.get("reservation_recorded"):
                spend_ledger_mark_cleaned(env, state)
            try:
                shared_capacity_release(env, state)
            except RunnerError as release_exc:
                combined = RunnerError(
                    "{}; pre-compute shared capacity release also failed: {}".format(
                        exc, release_exc
                    )
                )
                if state.get("phase") not in (
                    "cleanup-retained", "complete", "absent-fenced"
                ):
                    transition(env, state, "failed-retained", str(combined)[:500])
                raise combined from release_exc
        if state.get("phase") not in ("cleanup-retained", "complete", "absent-fenced"):
            transition(env, state, "failed-retained", str(exc)[:500])
        raise
    print_logs_and_summary(state, result)
    return int(result["exit_code"])


def print_logs_and_summary(state, result):
    # vm_instance_id and boot_id are the only evidence that this command ran on
    # Azure rather than through the dispatch's local fallback, and they used to
    # live ONLY in $FM_HOME/state/azure-runner/<invocation>.json. That left the
    # step's own log, and the no-mistakes run record built from it, unable to
    # distinguish a real cell execution from a local one. The proof of WHERE the
    # work ran belongs in the same artifact as the verdict, so it is printed
    # here, on the step's own stderr.
    print(
        "azure-runner: invocation={} exit={} timeout={} signal={} stdout_truncated={} stderr_truncated={} private_archive={} max_cost=${:.2f} vm_instance_id={} boot_id={}".format(
            state["invocation"], result["exit_code"], str(result["timed_out"]).lower(),
            result.get("signal") if result.get("signal") is not None else "none",
            str(result["stdout_truncated"]).lower(), str(result["stderr_truncated"]).lower(),
            state["staging"]["output_blob"],
            state.get("cost", {}).get("max_increment", 0.0),
            state.get("resources", {}).get("vm_instance_id") or "unrecorded",
            state.get("expected_boot_id") or "unrecorded",
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
    if (
        phase == "prepared"
        and state.get("shared_capacity_reservation", {}).get("status") == "queued"
    ):
        mode = state["request"].get(
            "cost_admission_mode", STRICT_COST_ADMISSION_MODE
        )
        confirmation = (
            COMMISSIONING_COST_ADMISSION_MODE
            if mode == COMMISSIONING_COST_ADMISSION_MODE
            else None
        )
        return dispatch_prepared(env, state, env["subscription"], confirmation)
    if phase in ("result-published", "failed-retained") and state.get("expected_result_digest"):
        result = collect_result(env, state)
        cleanup(env, state)
        print_logs_and_summary(state, result)
        return int(result["exit_code"])
    if phase in ("result-collected", "cleanup-retained", "compute-removed"):
        cleanup(env, state)
        print_logs_and_summary(state, state["result"])
        return int(state["result"]["exit_code"])
    if phase in (
        "prepared", "admission-checked", "cost-reserved", "vm-created", "command-submitted", "failed-retained"
    ):
        vm_exists, vm = get_vm(env, state)
        if vm_exists:
            foundation_gate(env)
            adopt_vm_identity(env, state, vm)
            command_exists, _ = run_command_exists(env, state)
            if not command_exists:
                create_run_command(env, state)
            else:
                transition(env, state, "command-submitted", "existing Managed Run Command adopted without resubmission")
            poll_run_command(env, state)
            result = collect_result(env, state)
            cleanup(env, state)
            print_logs_and_summary(state, result)
            return int(result["exit_code"])
        cleanup_partial_capacity(env, state)
        delete_private_snapshot(env, state)
        transition(env, state, "absent-fenced", "VM absent without a verified result; invocation marked dead")
        if state.get("reservation_recorded"):
            spend_ledger_mark_cleaned(env, state)
        shared_capacity_release(env, state)
        raise RunnerError("runner VM is absent without a verified result; retry requires a new fenced attempt")
    raise RunnerError("invocation phase {} cannot be resumed automatically".format(phase))


def retry(env, old_state, args):
    bind_operation_context(env, old_state)
    if old_state.get("phase") != "absent-fenced":
        raise RunnerError("retry requires the old invocation to be marked absent-fenced by resume")
    scope_gate(env)
    # A simple VM-existence check is the whole fence: absent means the dead
    # invocation cannot rerun and a fresh lineage attempt may start.
    vm_exists, _ = get_vm(env, old_state)
    if vm_exists:
        raise RunnerError("old invocation absence no longer holds; retry is fenced")
    current = Path(old_state["repository_root"]).resolve()
    if git(current, "rev-parse", "HEAD").stdout.strip() != old_state["request"]["repository"]["commit"]:
        raise RunnerError("retry repository HEAD differs from the fenced old snapshot")
    reprove_public_request(old_state)
    args.repo = str(current)
    args.task = old_state["request"]["task"]
    args.generation = old_state["request"]["generation"]
    args.resource_class = old_state["request"]["resource_class"]
    args.capacity_parent = old_state["request"].get("capacity_parent")
    args.capacity_reservation_vcpus = old_state["request"].get("capacity_reservation_vcpus")
    args.capacity_fence = old_state["request"].get("capacity_fence")
    repository = old_state["request"]["repository"]
    private_source = repository.get("source_mode") in (
        "private-parent-bundle",
        "private-exact-bundle",
        "private-direct-bundle",
    )
    private_parent_source = repository.get("source_mode") == "private-parent-bundle"
    private_exact_source = repository.get("source_mode") == "private-exact-bundle"
    private_direct_source = repository.get("source_mode") == "private-direct-bundle"
    selected_source_ref = (
        repository["source_ref"]
        if repository["source_ref"] != repository["default_ref"]
        else None
    )
    if private_source or not repository.get("source_ancestors"):
        args.source_ref = selected_source_ref
        args.public_ref = None
    else:
        args.source_ref = None
        args.public_ref = selected_source_ref
    args.public_ancestor = list(repository.get("source_ancestors", []))
    args.private_snapshot_from_head = private_direct_source
    args.private_snapshot_bundle = (
        str(Path(old_state["input_path"]).parent / "snapshot.bundle")
        if private_parent_source or private_exact_source
        else None
    )
    args.wall_seconds = old_state["request"]["limits"]["wall_seconds"]
    args.dependency = [item["path"] for item in old_state["request"].get("dependencies", [])]
    args.artifact = list(old_state["request"].get("artifacts", []))
    args.command = list(old_state["request"]["command"]["argv"])
    args.invocation = None
    with state_lock(env):
        state = prepare(env, args, parent_state=old_state)
    bind_operation_context(env, state)
    with invocation_lock(env, state["invocation"]):
        return dispatch_prepared(env, state, args.confirm_subscription, args.confirm_cost_admission_mode)


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
    parser.add_argument("--public-ref")
    parser.add_argument("--public-ancestor", action="append", default=[])
    parser.add_argument("--resource-class", choices=sorted(RESOURCE_CLASSES), default="validation-standard")
    parser.add_argument(
        "--capacity-parent",
        help="exact parent cell whose processor reservation already covers this invocation",
    )
    parser.add_argument("--capacity-reservation-vcpus", type=int)
    parser.add_argument(
        "--capacity-fence",
        help="exact parent shape fence so this invocation re-admits its pre-reserved constituent",
    )
    parser.add_argument("--wall-seconds", type=int)
    parser.add_argument(
        "--source-ref",
        help="exact branch or PR-head identity for a public remote or private snapshot",
    )
    parser.add_argument(
        "--private-snapshot-bundle",
        help="exact parent-cell Git bundle staged privately for an unpushed validation head",
    )
    parser.add_argument(
        "--private-snapshot-from-head",
        action="store_true",
        help="seal the exact clean non-shallow HEAD into a direct one-ref private bundle",
    )
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
    run_parser.add_argument("--confirm-cost-admission-mode")
    resume_parser = sub.add_parser("resume", help="resume collection/cleanup without duplicating execution")
    resume_parser.add_argument("--invocation", required=True)
    retry_parser = sub.add_parser("retry", help="create a new fenced attempt after proven old-lease absence")
    retry_parser.add_argument("--invocation", required=True)
    retry_parser.add_argument("--confirm-run", action="store_true")
    retry_parser.add_argument("--confirm-subscription")
    retry_parser.add_argument("--confirm-cost-admission-mode")
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
            return dispatch_prepared(env, state, args.confirm_subscription, args.confirm_cost_admission_mode)
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
