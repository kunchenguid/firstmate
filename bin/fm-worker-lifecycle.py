#!/usr/bin/env python3
"""Provider-neutral queue and lifecycle owner for elastic task workers.

The controller deliberately does not decide that work is landed or safe to
remove.  It consumes an exact release receipt from the ordinary Firstmate
owners, serializes one idempotent provider action at a time, and retains every
ambiguous assignment for investigation.

The provider protocol is JSON over stdin/stdout.  Set FM_WORKER_PROVIDER_COMMAND
for a different implementation; Azure is the default adapter.
See docs/azure-workers.md and `bin/fm-worker-lifecycle.sh help`.
"""

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
AZURE_PROVIDER = ROOT / "bin" / "fm-azure-worker-provider.py"
STATE_SCHEMA = "fm.worker-lifecycle/v1"
REQUEST_SCHEMA = "fm.worker-request/v1"
EXECUTION_SCHEMA = "fm.worker-execution/v1"
EXECUTION_RESULT_SCHEMA = "fm.worker-execution-result/v1"
RELEASE_SCHEMA = "fm.worker-release/v2"
AUTHORITY_SCHEMA = "fm.worker-authority/v1"
CAPACITY_RESERVATION_SCHEMA = "fm.capacity-reservation/v1"
SPECIALIZED_WORKLOAD_ROLES = ("validation", "review", "browser", "networkless-verifier", "crosscheck")
PROVIDER_REQUEST_SCHEMA = "fm.worker-provider-request/v1"
PROVIDER_RESPONSE_SCHEMA = "fm.worker-provider-response/v1"
SAFE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,63}$")
HEX_BINDING = re.compile(r"^[0-9a-f]{64}$")
UUID = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
MAX_WORKERS = 16
VCPUS_PER_WORKER = 4
REGIONAL_ADMISSION_CEILING_VCPUS = 128
AUTHOR_PLAN_VCPUS = MAX_WORKERS * VCPUS_PER_WORKER
SPECIALIZED_SHAPE_VCPUS = 40
SHARED_HEADROOM_VCPUS = 22
REGIONAL_NON_AUTHOR_RESERVE_VCPUS = SPECIALIZED_SHAPE_VCPUS + SHARED_HEADROOM_VCPUS
DEFAULT_COOLDOWN_SECONDS = 300
PROVIDER_TIMEOUT_SECONDS = 300
MAX_PROVIDER_OUTPUT_BYTES = 2 * 1024 * 1024
REQUIRED_RESOURCE_KINDS = (
    "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
    "role-assignment", "state-container", "monitor-extension", "bootstrap-command",
    "task-command", "ttl-schedule", "global-reservation", "staging-request",
    "staging-result",
)
REVIEWED_SKU_FAMILY = {
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
REVIEWED_CONTROL_SKU_FAMILY = {
    "Standard_D8as_v6": "standardDav6Family",
    "Standard_D8as_v7": "StandardDasv7Family",
    "Standard_D8s_v6": "StandardDsv6Family",
    "Standard_D8ads_v7": "StandardDadsv7Family",
    "Standard_D8ds_v6": "StandardDdsv6Family",
    "Standard_D8s_v7": "StandardDsv7Family",
    "Standard_D8ds_v7": "StandardDdsv7Family",
    "Standard_D8ads_v6": "standardDadv6Family",
    "Standard_E8as_v7": "StandardEasv7Family",
    "Standard_E8as_v6": "standardEav6Family",
}
SKU_PLAN = {
    1: ("Standard_D4as_v6", "standardDav6Family"),
    2: ("Standard_D4as_v6", "standardDav6Family"),
    3: ("Standard_D4as_v7", "StandardDasv7Family"),
    4: ("Standard_D4as_v7", "StandardDasv7Family"),
    5: ("Standard_D4s_v6", "StandardDsv6Family"),
    6: ("Standard_D4s_v6", "StandardDsv6Family"),
    7: ("Standard_D4ads_v7", "StandardDadsv7Family"),
    8: ("Standard_D4ads_v7", "StandardDadsv7Family"),
    9: ("Standard_D4ads_v6", "standardDadv6Family"),
    10: ("Standard_D4ads_v6", "standardDadv6Family"),
    11: ("Standard_E4as_v7", "StandardEasv7Family"),
    12: ("Standard_E4as_v7", "StandardEasv7Family"),
    13: ("Standard_E4as_v6", "standardEav6Family"),
    14: ("Standard_E4as_v6", "standardEav6Family"),
    15: ("Standard_D4ds_v6", "StandardDdsv6Family"),
    16: ("Standard_D4ds_v6", "StandardDdsv6Family"),
}


class LifecycleError(RuntimeError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def digest_value(value):
    return hashlib.sha256(canonical_bytes(value)).hexdigest()


def home_binding(path):
    return hashlib.sha256(str(path.resolve()).encode("utf-8")).hexdigest()


def now_utc():
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value=None):
    value = value or now_utc()
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")


def parse_time(value):
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, TypeError, ValueError):
        raise LifecycleError("durable lifecycle timestamp is malformed")


def require_id(label, value):
    if not isinstance(value, str) or not SAFE_ID.match(value):
        raise LifecycleError("{} must use 1-64 bounded identifier characters".format(label))
    return value


def require_binding(label, value):
    if not isinstance(value, str) or not HEX_BINDING.match(value):
        raise LifecycleError("{} must be an exact lowercase SHA-256 binding".format(label))
    return value


def require_uuid(label, value):
    if not isinstance(value, str) or not UUID.match(value):
        raise LifecycleError("{} must be an exact UUID".format(label))
    return value.lower()


def read_json(path, label):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise LifecycleError("{} is absent".format(label))
    except (OSError, json.JSONDecodeError) as exc:
        raise LifecycleError("{} is unreadable: {}".format(label, exc))
    if not isinstance(value, dict):
        raise LifecycleError("{} must be a JSON object".format(label))
    return value


def save_json_atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
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


def environment():
    home = Path(os.environ.get("FM_HOME", str(ROOT))).resolve()
    subscription = require_uuid(
        "FM_AZURE_SUBSCRIPTION_ID", os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "")
    )
    deployment_generation = require_id(
        "FM_AZURE_DEPLOYMENT_GENERATION", os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION", "")
    )
    owner = require_id("FM_AZURE_OWNER_TAG", os.environ.get("FM_AZURE_OWNER_TAG", ""))
    prefix = os.environ.get("FM_AZURE_NAMING_PREFIX", "")
    if not re.match(r"^[a-z0-9]{3,12}$", prefix):
        raise LifecycleError("FM_AZURE_NAMING_PREFIX must be 3-12 lowercase alphanumeric characters")
    state_dir = Path(os.environ.get(
        "FM_AZURE_WORKER_STATE_DIR", str(home / "state" / "azure-workers")
    )).resolve()
    max_workers = int(os.environ.get("FM_AZURE_WORKER_MAX", "16"))
    if max_workers < 1 or max_workers > MAX_WORKERS:
        raise LifecycleError("FM_AZURE_WORKER_MAX must be between 1 and 16")
    cooldown = int(os.environ.get(
        "FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS", str(DEFAULT_COOLDOWN_SECONDS)
    ))
    if cooldown < 0 or cooldown > 1800:
        raise LifecycleError("FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS must be between 0 and 1800")
    warm_idle = int(os.environ.get("FM_AZURE_WORKER_WARM_IDLE", "0"))
    if warm_idle != 0:
        raise LifecycleError("FM_AZURE_WORKER_WARM_IDLE currently must remain zero")
    phase = os.environ.get("FM_AZURE_WORKER_POLICY_PHASE", "commissioning")
    if phase not in ("commissioning", "steady"):
        raise LifecycleError("FM_AZURE_WORKER_POLICY_PHASE must be commissioning or steady")
    steady_target = float(os.environ.get("FM_AZURE_WORKER_STEADY_TARGET_USD", "1000"))
    if steady_target < 500 or steady_target > 1500:
        raise LifecycleError("FM_AZURE_WORKER_STEADY_TARGET_USD must be between 500 and 1500")
    commissioning_ceiling = float(os.environ.get("FM_AZURE_WORKER_COMMISSIONING_CEILING_USD", "1500"))
    if commissioning_ceiling != 1500:
        raise LifecycleError("commissioning author admission ceiling must remain exactly 1500 USD")
    forecast_hours = float(os.environ.get("FM_AZURE_WORKER_ADMISSION_HOURS", "24"))
    if forecast_hours < 1 or forecast_hours > 168:
        raise LifecycleError("FM_AZURE_WORKER_ADMISSION_HOURS must be between 1 and 168")
    planning_hours = float(os.environ.get("FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD", "3500"))
    if planning_hours <= 0:
        raise LifecycleError("FM_AZURE_WORKER_HOUR_PLANNING_THRESHOLD must be positive")
    provider_command = os.environ.get(
        "FM_WORKER_PROVIDER_COMMAND", "python3 {}".format(shlex.quote(str(AZURE_PROVIDER)))
    )
    provider_argv = shlex.split(provider_command)
    if not provider_argv:
        raise LifecycleError("FM_WORKER_PROVIDER_COMMAND is empty")
    return {
        "home": home,
        "home_binding": home_binding(home),
        "subscription": subscription,
        "deployment_generation": deployment_generation,
        "owner": owner,
        "prefix": prefix,
        "resource_group": os.environ.get("FM_AZURE_RESOURCE_GROUP", "rg-firstmate-pilot-eastus-001"),
        "state_dir": state_dir,
        "state_path": state_dir / "controller.json",
        "lock_path": state_dir / ".lock",
        "max_workers": max_workers,
        "cooldown_seconds": cooldown,
        "warm_idle": warm_idle,
        "policy_phase": phase,
        "steady_target_usd": steady_target,
        "commissioning_ceiling_usd": commissioning_ceiling,
        "admission_hours": forecast_hours,
        "planning_hours": planning_hours,
        "provider_argv": provider_argv,
    }


@contextlib.contextmanager
def controller_lock(env):
    env["state_dir"].mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(env["state_dir"], 0o700)
    with open(env["lock_path"], "a+", encoding="utf-8") as handle:
        os.chmod(env["lock_path"], 0o600)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield


def empty_state(env):
    return {
        "schema": STATE_SCHEMA,
        "home_binding": env["home_binding"],
        "subscription_binding": hashlib.sha256(env["subscription"].encode("ascii")).hexdigest(),
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
        "prefix": env["prefix"],
        "created_at": iso_utc(),
        "updated_at": iso_utc(),
        "next_assignment": 1,
        "queue": {},
        "workers": {},
        "capacity_reservations": {},
        "completed_worker_seconds": 0.0,
        "pending_action": None,
        "cleanup_refusals": [],
        "last_metrics": None,
        "executions": {},
    }


def verify_state(env, state):
    expected = empty_state(env)
    for field in (
        "schema", "home_binding", "subscription_binding", "deployment_generation", "owner", "prefix"
    ):
        if state.get(field) != expected[field]:
            raise LifecycleError("lifecycle state {} binding is not exact".format(field))
    if (
        not isinstance(state.get("queue"), dict)
        or not isinstance(state.get("workers"), dict)
        or not isinstance(state.get("capacity_reservations"), dict)
        or not isinstance(state.get("executions"), dict)
    ):
        raise LifecycleError("lifecycle queue, worker, or shared capacity inventory is malformed")
    live_reservations = sum(
        1 for item in state["capacity_reservations"].values()
        if isinstance(item, dict) and item.get("status") != "released"
    )
    if live_reservations > 256:
        raise LifecycleError("shared capacity reservation history exceeds its durable bound")
    for reservation_id, reservation in state["capacity_reservations"].items():
        if not isinstance(reservation, dict):
            raise LifecycleError("durable specialized capacity reservation is malformed")
        if reservation.get("vcpus") == 4:
            reviewed_family = REVIEWED_SKU_FAMILY.get(reservation.get("sku"))
        elif reservation.get("vcpus") == 8:
            reviewed_family = REVIEWED_CONTROL_SKU_FAMILY.get(reservation.get("sku"))
        else:
            reviewed_family = None
        if (
            reservation_id != reservation.get("reservation_id")
            or reservation.get("schema") != CAPACITY_RESERVATION_SCHEMA
            or reservation.get("role") != "specialized"
            or reservation.get("status") not in ("queued", "reserved", "released")
            or reviewed_family is None
            or str(reservation.get("sku_family", "")).lower() != reviewed_family.lower()
            or isinstance(reservation.get("amount_usd"), bool)
            or not isinstance(reservation.get("amount_usd"), (int, float))
            or not math.isfinite(float(reservation["amount_usd"]))
            or reservation["amount_usd"] <= 0
        ):
            raise LifecycleError("durable specialized capacity reservation is malformed")
        require_id("capacity reservation id", reservation_id)
        require_binding("capacity reservation fence", reservation.get("fence_binding"))
        if "shape_id" in reservation:
            require_id("capacity shape id", reservation.get("shape_id"))
    if state.get("pending_action") is not None and not isinstance(state["pending_action"], dict):
        raise LifecycleError("pending provider action is malformed")


def load_state(env):
    try:
        state = read_json(env["state_path"], "lifecycle state")
    except LifecycleError as exc:
        if "is absent" not in str(exc):
            raise
        state = empty_state(env)
    state.setdefault("capacity_reservations", {})
    state.setdefault("executions", {})
    verify_state(env, state)
    return state


def save_state(env, state):
    state["updated_at"] = iso_utc()
    verify_state(env, state)
    save_json_atomic(env["state_path"], state)


def request_key(task, generation):
    return "{}@{}".format(task, generation)


def verify_request(request):
    if request.get("schema") != REQUEST_SCHEMA:
        raise LifecycleError("worker request schema is not supported")
    for field in ("task", "task_generation", "repository_generation"):
        require_id(field, request.get(field))
    for field in ("home_binding", "account_binding", "worktree_binding", "repository_binding"):
        require_binding(field, request.get(field))
    if request.get("role") != "author":
        raise LifecycleError("general worker requests must use the single-agent author role")
    if request.get("owner_kind") not in ("primary", "secondmate"):
        raise LifecycleError("worker request owner_kind must be primary or secondmate")
    if request.get("eligible") is not True:
        raise LifecycleError("worker request must be explicitly eligible")


def active_queue_items(state):
    return [item for item in state["queue"].values() if item.get("status") != "complete"]


def ensure_unique_bindings(state, candidate, ignore_key=None):
    for key, item in state["queue"].items():
        if key == ignore_key or item.get("status") == "complete":
            continue
        if item.get("account_binding") == candidate["account_binding"]:
            raise LifecycleError("provider-account lease binding is already owned by another queued or active task")
        if item.get("worktree_binding") == candidate["worktree_binding"]:
            raise LifecycleError("writable worktree binding is already owned by another queued or active task")


def provider_call(env, operation, action=None):
    request = {
        "schema": PROVIDER_REQUEST_SCHEMA,
        "operation": operation,
        "controller": {
            "home_binding": env["home_binding"],
            "subscription": env["subscription"],
            "deployment_generation": env["deployment_generation"],
            "owner": env["owner"],
            "prefix": env["prefix"],
            "resource_group": env["resource_group"],
        },
    }
    if action is not None:
        request["action"] = action
    try:
        result = subprocess.run(
            env["provider_argv"], input=canonical_bytes(request) + b"\n",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=PROVIDER_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LifecycleError("provider operation is unavailable or exceeded its bounded deadline: {}".format(exc))
    if len(result.stdout) > MAX_PROVIDER_OUTPUT_BYTES or len(result.stderr) > MAX_PROVIDER_OUTPUT_BYTES:
        raise LifecycleError("provider response exceeded its bounded output allowance")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise LifecycleError("provider {} failed{}".format(operation, ": " + detail if detail else ""))
    try:
        response = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise LifecycleError("provider returned malformed JSON: {}".format(exc))
    verify_provider_response(env, operation, response)
    return response


def verify_provider_response(env, operation, response):
    if not isinstance(response, dict) or response.get("schema") != PROVIDER_RESPONSE_SCHEMA:
        raise LifecycleError("provider response schema is not supported")
    if response.get("operation") != operation:
        raise LifecycleError("provider response operation binding is not exact")
    controller = response.get("controller") or {}
    for field in ("home_binding", "subscription", "deployment_generation", "owner", "prefix", "resource_group"):
        expected = env[field]
        if controller.get(field) != expected:
            raise LifecycleError("provider response {} binding is not exact".format(field))
    if operation == "inventory":
        verify_inventory(response.get("inventory"))


def verify_inventory(inventory):
    if not isinstance(inventory, dict) or inventory.get("schema") != "fm.worker-provider-inventory/v1":
        raise LifecycleError("provider inventory schema is not supported")
    workers = inventory.get("workers")
    metrics = inventory.get("metrics")
    if not isinstance(workers, list) or len(workers) > MAX_WORKERS or not isinstance(metrics, dict):
        raise LifecycleError("provider inventory is malformed or exceeds sixteen workers")
    slots = set()
    resource_ids = set()
    for worker in workers:
        slot = worker.get("slot")
        if not isinstance(slot, int) or slot < 1 or slot > MAX_WORKERS or slot in slots:
            raise LifecycleError("provider worker slot inventory is invalid or duplicated")
        slots.add(slot)
        resources = worker.get("resources") or {}
        if not isinstance(resources, dict):
            raise LifecycleError("provider worker resource inventory is malformed")
        for kind, resource in resources.items():
            if kind not in REQUIRED_RESOURCE_KINDS or not isinstance(resource, dict):
                raise LifecycleError("provider returned an unsupported worker resource kind")
            resource_id = resource.get("id")
            if not isinstance(resource_id, str) or not resource_id or resource_id.lower() in resource_ids:
                raise LifecycleError("provider resource identity is absent or duplicated")
            resource_ids.add(resource_id.lower())
    if not isinstance(inventory.get("conflicts", []), list):
        raise LifecycleError("provider conflict inventory is malformed")
    capacity_reservations = inventory.get("capacity_reservations", [])
    if not isinstance(capacity_reservations, list) or len(capacity_reservations) > 64:
        raise LifecycleError("provider capacity reservation inventory is malformed or unbounded")
    seen_reservations = set()
    for reservation in capacity_reservations:
        reservation_id = reservation.get("reservation_id") if isinstance(reservation, dict) else None
        if isinstance(reservation, dict) and reservation.get("vcpus") == 4:
            reviewed_family = REVIEWED_SKU_FAMILY.get(reservation.get("sku"))
        elif isinstance(reservation, dict) and reservation.get("vcpus") == 8:
            reviewed_family = REVIEWED_CONTROL_SKU_FAMILY.get(reservation.get("sku"))
        else:
            reviewed_family = None
        if (
            not isinstance(reservation_id, str)
            or not SAFE_ID.match(reservation_id)
            or reservation_id in seen_reservations
            or reservation.get("role") != "specialized"
            or reviewed_family is None
            or str(reservation.get("sku_family", "")).lower() != reviewed_family.lower()
            or isinstance(reservation.get("amount_usd"), bool)
            or not isinstance(reservation.get("amount_usd"), (int, float))
            or not math.isfinite(float(reservation["amount_usd"]))
            or reservation["amount_usd"] <= 0
            or not isinstance(reservation.get("active"), bool)
        ):
            raise LifecycleError("provider capacity reservation identity is not exact")
        seen_reservations.add(reservation_id)


def bindings_for_item(item, assignment_generation):
    return {
        "home_binding": item["home_binding"],
        "task": item["task"],
        "task_generation": item["task_generation"],
        "assignment_generation": assignment_generation,
        "account_binding": item["account_binding"],
        "worktree_binding": item["worktree_binding"],
        "repository_binding": item["repository_binding"],
        "repository_generation": item["repository_generation"],
    }


def expected_tags(worker):
    bindings = worker["bindings"]
    return {
        "workload": "firstmate",
        "firstmate-role": "worker",
        "deployment-generation": worker["deployment_generation"],
        "cleanup-owner": worker["owner"],
        "worker-slot": str(worker["slot"]),
        "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"],
        "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "account-binding": bindings["account_binding"],
        "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "agent-capacity": "one-task-scoped-crewmate",
        "nested-team": "forbidden",
        "secondmate-placement": "forbidden",
        "browser-profile": "forbidden",
    }


def inventory_by_slot(inventory):
    return {worker["slot"]: worker for worker in inventory["workers"]}


def resource_identity(resource):
    return {
        "id": resource.get("id"),
        "immutable_id": resource.get("immutable_id"),
    }


def resources_exact(worker, cloud, allow_missing_compute=False):
    resources = cloud.get("resources") or {}
    recorded = worker.get("resources") or {}
    missing = []
    for kind in REQUIRED_RESOURCE_KINDS:
        current = resources.get(kind)
        prior = recorded.get(kind)
        if current is None:
            if allow_missing_compute and kind in (
                "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command",
                "task-command", "ttl-schedule", "staging-request", "staging-result",
            ):
                continue
            missing.append(kind)
            continue
        if prior is not None and resource_identity(current) != resource_identity(prior):
            return False, "{} immutable identity changed".format(kind)
        tags = current.get("tags") or {}
        for key, value in expected_tags(worker).items():
            if kind in ("role-assignment", "state-container") and key not in tags:
                continue
            if tags.get(key) != value:
                return False, "{} tag mismatch: {}".format(kind, key)
    if missing:
        return False, "missing exact resources: {}".format(", ".join(missing))
    return True, ""


def classify_worker(worker, cloud, now=None):
    now = now or now_utc()
    if cloud is None:
        if worker["phase"] in ("creating", "resuming"):
            return "retained-for-investigation", "capacity absent during a submitted create"
        if worker["phase"] in ("compute-removed", "resetting"):
            return "orphaned-safe-to-delete", "release proof owns exact residual cleanup"
        return "retained-for-investigation", "recorded assignment has no exact cloud capacity"
    exact, reason = resources_exact(worker, cloud, allow_missing_compute=True)
    if not exact:
        return "retained-for-investigation", reason
    resources = cloud.get("resources") or {}
    vm = resources.get("vm")
    task_disk = resources.get("task-disk")
    account_disk = resources.get("account-disk")
    if vm is None:
        if task_disk or account_disk:
            if worker.get("release_proof") and worker["phase"] in ("compute-removed", "resetting"):
                return "orphaned-safe-to-delete", "exact released residual data capacity"
            return "retained-for-investigation", "VM missing while task or account disk remains"
        return "retained-for-investigation", "VM and durable task identity are both absent"
    power = str(vm.get("power_state", "unknown")).lower()
    if worker.get("release_proof"):
        started = worker.get("cooldown_started_at")
        if "deallocated" in power and started:
            age = max(0, int((now - parse_time(started)).total_seconds()))
            return "deallocated", "idle cooldown age {} seconds".format(age)
        if "deallocated" in power:
            return "deallocated", "idle worker compute is dark"
    if worker.get("bindings", {}).get("task") == "unbound":
        return "clean-warm", "fresh unassigned generation"
    return "assigned", "one exact active task generation"


def adopt_cloud_resources(worker, cloud):
    resources = cloud.get("resources") or {}
    if set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise LifecycleError("created worker did not return the complete exact resource set")
    worker["resources"] = {
        kind: resource_identity(resources[kind]) for kind in REQUIRED_RESOURCE_KINDS
    }
    exact, reason = resources_exact(worker, cloud)
    if not exact:
        raise LifecycleError("created worker identity is not exact: {}".format(reason))
    vm = resources["vm"]
    worker["cloud_instance_id"] = vm["immutable_id"]
    worker["phase"] = "assigned"
    worker["assigned_at"] = worker.get("assigned_at") or iso_utc()
    worker["last_classification"] = "assigned"


def metrics_from_inventory(inventory):
    metrics = inventory["metrics"]
    result = {
        "actual_usd": metrics.get("actual_usd"),
        "forecast_usd": metrics.get("forecast_usd"),
        "forecast_untrained": metrics.get("forecast_untrained"),
        "regional_limit_vcpus": metrics.get("regional_limit_vcpus"),
        "regional_used_vcpus": metrics.get("regional_used_vcpus"),
        "specialized_active_vcpus": metrics.get("specialized_active_vcpus"),
        "specialized_active_by_family": metrics.get("specialized_active_by_family"),
        "family_limit_vcpus": metrics.get("family_limit_vcpus"),
        "family_used_vcpus": metrics.get("family_used_vcpus"),
        "family_free_vcpus": metrics.get("family_free_vcpus"),
        "capacity_reservations": inventory.get("capacity_reservations", []),
        "sku_hourly_usd": metrics.get("sku_hourly_usd"),
        "observed_at": inventory.get("observed_at"),
    }
    return result


def worker_seconds(state, now=None):
    now = now or now_utc()
    total = float(state.get("completed_worker_seconds", 0.0))
    for worker in state["workers"].values():
        if worker.get("assigned_at") and not worker.get("released_at"):
            total += max(0.0, (now - parse_time(worker["assigned_at"])).total_seconds())
    return total


def budget_limit(env):
    if env["policy_phase"] == "commissioning":
        return env["commissioning_ceiling_usd"]
    return env["steady_target_usd"]


def active_count(state, inventory):
    cloud = inventory_by_slot(inventory)
    count = 0
    for worker in state["workers"].values():
        current = cloud.get(worker["slot"])
        if current and current.get("resources", {}).get("vm"):
            power = str(current["resources"]["vm"].get("power_state", "")).lower()
            if "deallocated" not in power:
                count += 1
    return count


def ignored_reservation_ids(ignore_reservation_id):
    if ignore_reservation_id is None:
        return frozenset()
    if isinstance(ignore_reservation_id, str):
        return frozenset((ignore_reservation_id,))
    return frozenset(ignore_reservation_id)


def merged_specialized_reservations(state, inventory, ignore_reservation_id=None):
    ignored = ignored_reservation_ids(ignore_reservation_id)
    merged = {}
    for reservation in inventory.get("capacity_reservations", []):
        if reservation["reservation_id"] in ignored:
            continue
        merged[reservation["reservation_id"]] = dict(reservation)
    for reservation_id, local in state.get("capacity_reservations", {}).items():
        if reservation_id in ignored or local.get("status") != "reserved":
            continue
        current = merged.get(reservation_id)
        identity_fields = ("role", "sku", "sku_family", "vcpus", "amount_usd")
        if current is not None and (
            any(current.get(field) != local.get(field) for field in ("role", "sku", "vcpus"))
            or str(current.get("sku_family", "")).lower() != str(local.get("sku_family", "")).lower()
            or not math.isclose(
                float(current.get("amount_usd", -1.0)), float(local.get("amount_usd", -2.0)),
                rel_tol=0.0, abs_tol=1e-6,
            )
        ):
            raise LifecycleError("local and provider specialized reservation identity differs")
        if current is None:
            current = {field: local[field] for field in identity_fields}
            current.update({"reservation_id": reservation_id, "active": False})
            merged[reservation_id] = current
    return merged


def capacity_commitments(state, inventory, provisional=(), ignore_reservation_id=None):
    metrics = inventory["metrics"]
    regional_limit = metrics.get("regional_limit_vcpus")
    regional_used = metrics.get("regional_used_vcpus")
    family_limit = metrics.get("family_limit_vcpus")
    family_used = metrics.get("family_used_vcpus")
    if not isinstance(regional_limit, int) or not isinstance(regional_used, int):
        raise LifecycleError("shared East US regional quota is unreadable")
    if regional_limit < REGIONAL_ADMISSION_CEILING_VCPUS:
        raise LifecycleError("shared East US regional quota is below the reviewed 128-vCPU ceiling")
    if not isinstance(family_limit, dict) or not isinstance(family_used, dict):
        raise LifecycleError("exact selected-family quota inventory is unreadable")

    cloud = inventory_by_slot(inventory)
    active_by_family = {}
    pending_by_family = {}
    active_total = 0
    pending_total = 0
    specialized_committed = 0
    for slot, current in cloud.items():
        vm = (current.get("resources") or {}).get("vm")
        if vm is None or "deallocated" in str(vm.get("power_state", "")).lower():
            continue
        family = SKU_PLAN[slot][1]
        active_by_family[family] = active_by_family.get(family, 0) + VCPUS_PER_WORKER
        active_total += VCPUS_PER_WORKER
    for worker in state["workers"].values():
        if worker.get("released_at") or worker["slot"] in cloud and (cloud[worker["slot"]].get("resources") or {}).get("vm"):
            continue
        family = worker["sku_family"]
        pending_by_family[family] = pending_by_family.get(family, 0) + VCPUS_PER_WORKER
        pending_total += VCPUS_PER_WORKER

    specialized = merged_specialized_reservations(
        state, inventory, ignore_reservation_id=ignore_reservation_id
    )
    for reservation in specialized.values():
        family = reservation["sku_family"]
        vcpus = reservation["vcpus"]
        specialized_committed += vcpus
        if reservation["active"]:
            active_by_family[family] = active_by_family.get(family, 0) + vcpus
            active_total += vcpus
        else:
            pending_by_family[family] = pending_by_family.get(family, 0) + vcpus
            pending_total += vcpus
    for reservation in provisional:
        family = reservation["sku_family"]
        vcpus = reservation["vcpus"]
        pending_by_family[family] = pending_by_family.get(family, 0) + vcpus
        pending_total += vcpus
        if reservation["role"] == "specialized":
            specialized_committed += vcpus

    family_committed = {}
    for family in set(family_limit) | set(active_by_family) | set(pending_by_family):
        observed = family_used.get(family)
        limit = family_limit.get(family)
        if not isinstance(observed, int) or not isinstance(limit, int):
            raise LifecycleError("exact selected-family observed usage or limit is unreadable")
        family_committed[family] = max(observed, active_by_family.get(family, 0)) + pending_by_family.get(family, 0)
    return {
        "regional_limit": regional_limit,
        "regional_committed": max(regional_used, active_total) + pending_total,
        "family_limit": family_limit,
        "family_committed": family_committed,
        "specialized_committed": specialized_committed,
        "specialized_reservations": specialized,
    }


def outstanding_cost_reservations(
    state, inventory, provisional=(), ignore_reservation_id=None
):
    author = sum(
        float(worker.get("reservation_usd", 0.0))
        for worker in state["workers"].values()
        if not worker.get("released_at")
    )
    specialized = sum(
        float(reservation["amount_usd"])
        for reservation in merged_specialized_reservations(
            state, inventory, ignore_reservation_id=ignore_reservation_id
        ).values()
    )
    projected = sum(float(reservation["amount_usd"]) for reservation in provisional)
    return author + specialized + projected


def capacity_admission(
    env, state, inventory, candidate, provisional=(), ignore_reservation_id=None
):
    metrics = inventory["metrics"]
    actual = metrics.get("actual_usd")
    forecast = metrics.get("forecast_usd")
    if (
        forecast is None
        and metrics.get("forecast_untrained") is True
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
        and env["policy_phase"] == "commissioning"
        and os.environ.get("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST") == "1"
    ):
        # Bootstrap-only seam: a fresh resource group cannot train the
        # forecast model until real spend exists. With the operator's explicit
        # commissioning confirmation, the readable actual substitutes as the
        # conservative forecast; any other unreadable telemetry still refuses.
        forecast = float(actual)
    if not isinstance(actual, (int, float)) or not isinstance(forecast, (int, float)):
        return False, "shared actual or forecast spend is unreadable"
    try:
        commitments = capacity_commitments(
            state, inventory, provisional, ignore_reservation_id=ignore_reservation_id
        )
    except LifecycleError as exc:
        return False, str(exc)
    family = candidate["sku_family"]
    vcpus = candidate["vcpus"]
    family_limit = commitments["family_limit"].get(family)
    family_committed = commitments["family_committed"].get(family)
    if not isinstance(family_limit, int) or not isinstance(family_committed, int):
        return False, "exact selected-family observed-plus-reserved capacity is unreadable"
    if family_committed + vcpus > family_limit:
        return False, "exact selected-family observed-plus-reserved capacity is exhausted"
    specialized_after = commitments["specialized_committed"]
    if candidate["role"] == "specialized":
        specialized_after += vcpus
        if specialized_after > SPECIALIZED_SHAPE_VCPUS:
            return False, "specialized observed-plus-reserved demand exceeds its shared 40-vCPU shape"
    reserve_remaining = max(0, SPECIALIZED_SHAPE_VCPUS - specialized_after)
    if (
        commitments["regional_committed"] + vcpus + reserve_remaining + SHARED_HEADROOM_VCPUS
        > REGIONAL_ADMISSION_CEILING_VCPUS
    ):
        return False, "combined observed-plus-reserved demand would consume the shared East US ceiling"
    pressure = (
        max(float(actual), float(forecast))
        + outstanding_cost_reservations(
            state, inventory, provisional, ignore_reservation_id=ignore_reservation_id
        )
        + float(candidate["amount_usd"])
    )
    if pressure >= budget_limit(env) and candidate.get("discretionary", True):
        return False, "shared actual/forecast spend plus durable reservations reaches the active policy limit"
    return True, ""


def admission_result(env, state, inventory, slot, item=None, provisional=()):
    sku, family = SKU_PLAN[slot]
    rates = inventory["metrics"].get("sku_hourly_usd")
    if not isinstance(rates, dict) or not isinstance(rates.get(sku), (int, float)):
        return False, "selected worker retail rate is unreadable", 0.0
    increment = round(float(rates[sku]) * env["admission_hours"] + 2.0, 6)
    candidate = {
        "reservation_id": "author-slot-{}".format(slot),
        "role": "author",
        "sku": sku,
        "sku_family": family,
        "vcpus": VCPUS_PER_WORKER,
        "amount_usd": increment,
        "discretionary": item is None or item.get("discretionary", True),
    }
    admitted, reason = capacity_admission(env, state, inventory, candidate, provisional)
    return admitted, reason, increment


def queued_items(state):
    return sorted(
        [item for item in state["queue"].values() if item.get("status") == "queued" and item.get("eligible")],
        key=lambda item: (item.get("enqueued_at", ""), item["task"], item["task_generation"]),
    )


def desired_count(env, state, inventory):
    total_work = sum(
        1 for item in state["queue"].values()
        if item.get("status") in ("queued", "assigning", "assigned") and item.get("eligible")
    )
    actual = active_count(state, inventory)
    waiting = queued_items(state)
    provisional = []
    for slot in range(1, env["max_workers"] + 1):
        if len(provisional) >= len(waiting) or str(slot) in state["workers"]:
            continue
        item = waiting[len(provisional)]
        admitted, _, increment = admission_result(
            env, state, inventory, slot, item, provisional=provisional
        )
        if not admitted:
            continue
        sku, family = SKU_PLAN[slot]
        provisional.append({
            "reservation_id": "projected-author-slot-{}".format(slot),
            "role": "author",
            "sku": sku,
            "sku_family": family,
            "vcpus": VCPUS_PER_WORKER,
            "amount_usd": increment,
            "discretionary": item.get("discretionary", True),
        })
    return max(actual, min(total_work, env["max_workers"], actual + len(provisional)))


def action_id(action):
    unsigned = dict(action)
    unsigned.pop("idempotency_key", None)
    return digest_value(unsigned)


def make_action(env, action_type, worker=None, item=None, **fields):
    action = {
        "type": action_type,
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
    }
    if worker is not None:
        action.update({
            "slot": worker["slot"],
            "sku": worker["sku"],
            "sku_family": worker["sku_family"],
            "cloud_generation": worker["cloud_generation"],
            "bindings": worker["bindings"],
            "resources": worker.get("resources", {}),
            "cloud_instance_id": worker.get("cloud_instance_id"),
            "reservation_usd": worker.get("reservation_usd"),
        })
    if item is not None:
        action["request"] = item
    action.update(fields)
    action["idempotency_key"] = action_id(action)
    return action


def next_assignment_generation(state):
    value = int(state.get("next_assignment", 1))
    state["next_assignment"] = value + 1
    return "asg-{:08d}".format(value)


def create_worker_record(env, state, slot, item, reservation):
    assignment_generation = next_assignment_generation(state)
    sku, family = SKU_PLAN[slot]
    return {
        "slot": slot,
        "sku": sku,
        "sku_family": family,
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
        "assignment_generation": assignment_generation,
        "cloud_generation": 1,
        "bindings": bindings_for_item(item, assignment_generation),
        "queue_key": request_key(item["task"], item["task_generation"]),
        "phase": "creating",
        "created_at": iso_utc(),
        "assigned_at": None,
        "released_at": None,
        "release_proof": None,
        "cooldown_started_at": None,
        "reservation_usd": reservation,
        "resources": {},
        "cloud_instance_id": None,
        "last_classification": "retained-for-investigation",
        "last_refusal": None,
    }


def record_refusal(state, worker, note):
    entry = {
        "at": iso_utc(),
        "slot": worker.get("slot") if worker else None,
        "assignment_generation": worker.get("assignment_generation") if worker else None,
        "note": str(note)[:500],
    }
    state["cleanup_refusals"].append(entry)
    state["cleanup_refusals"] = state["cleanup_refusals"][-20:]
    if worker is not None:
        worker["last_refusal"] = entry
        worker["last_classification"] = "retained-for-investigation"


def execute_action(env, state, action):
    state["pending_action"] = action
    save_state(env, state)
    response = provider_call(env, "mutate", action)
    result = response.get("result")
    if not isinstance(result, dict) or result.get("idempotency_key") != action["idempotency_key"]:
        raise LifecycleError("provider mutation result is not bound to the exact idempotency key")
    apply_action_result(env, state, action, result)
    state["pending_action"] = None
    save_state(env, state)


def apply_action_result(env, state, action, result):
    action_type = action["type"]
    slot = str(action.get("slot", ""))
    worker = state["workers"].get(slot) if slot else None
    if action_type in ("create", "resume"):
        if worker is None:
            raise LifecycleError("provider created capacity for an absent durable worker record")
        cloud = result.get("worker")
        if not isinstance(cloud, dict) or cloud.get("slot") != worker["slot"]:
            raise LifecycleError("provider create result returned the wrong worker slot")
        adopt_cloud_resources(worker, cloud)
        queue_item = state["queue"].get(worker["queue_key"])
        if queue_item is None:
            raise LifecycleError("created worker queue owner disappeared")
        queue_item["status"] = "assigned"
        queue_item["assignment_generation"] = worker["assignment_generation"]
        queue_item["slot"] = worker["slot"]
    elif action_type == "deallocate":
        if worker is None:
            raise LifecycleError("deallocate result has no durable worker owner")
        worker["phase"] = "deallocated"
        worker["cooldown_started_at"] = worker.get("cooldown_started_at") or iso_utc()
        worker["last_classification"] = "deallocated"
    elif action_type == "delete-compute":
        if worker is None:
            raise LifecycleError("compute deletion result has no durable worker owner")
        worker["phase"] = "compute-removed"
        cloud = result.get("worker")
        if cloud is not None:
            returned = cloud.get("resources") or {}
            for kind in (
                "task-disk", "account-disk", "identity", "role-assignment", "state-container",
                "global-reservation", "staging-request", "staging-result",
            ):
                resource = returned.get(kind)
                if resource is None:
                    raise LifecycleError("compute cleanup result lost exact retained {}".format(kind))
                worker.setdefault("resources", {})[kind] = resource_identity(resource)
        for kind in (
            "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command",
            "task-command", "ttl-schedule",
        ):
            worker.get("resources", {}).pop(kind, None)
        worker["cloud_instance_id"] = None
        worker["last_classification"] = "orphaned-safe-to-delete"
    elif action_type == "reset":
        if worker is None:
            raise LifecycleError("reset result has no durable worker owner")
        queue_item = state["queue"].get(worker["queue_key"])
        if queue_item is not None:
            queue_item["status"] = "complete"
            queue_item["completed_at"] = iso_utc()
        if worker.get("assigned_at"):
            end = parse_time(worker.get("released_at") or iso_utc())
            state["completed_worker_seconds"] = float(state.get("completed_worker_seconds", 0.0)) + max(
                0.0, (end - parse_time(worker["assigned_at"])).total_seconds()
            )
        state["workers"].pop(slot, None)
    elif action_type == "execute":
        if worker is None:
            raise LifecycleError("execute result has no durable worker owner")
        execution = result.get("execution")
        if not isinstance(execution, dict) or execution.get("schema") != EXECUTION_RESULT_SCHEMA:
            raise LifecycleError("provider execution result schema is not supported")
        if execution.get("request_digest") != action.get("request_digest"):
            raise LifecycleError("provider execution result is not bound to the exact request")
        supplied = execution.get("result_digest")
        unsigned = dict(execution)
        unsigned.pop("result_digest", None)
        if supplied != digest_value(unsigned):
            raise LifecycleError("provider execution result digest is not exact")
        for field, expected in (
            ("task", worker["bindings"]["task"]),
            ("task_generation", worker["bindings"]["task_generation"]),
            ("assignment_generation", worker["assignment_generation"]),
            ("cloud_instance_id", worker["cloud_instance_id"]),
            ("repository_binding", worker["bindings"]["repository_binding"]),
            ("repository_generation", worker["bindings"]["repository_generation"]),
        ):
            if execution.get(field) != expected:
                raise LifecycleError("provider execution {} binding differs".format(field))
        state["executions"][action["request_digest"]] = execution
        worker["last_execution_digest"] = supplied
        worker["last_execution_at"] = iso_utc()
    elif action_type == "steer":
        if worker is None:
            raise LifecycleError("steer result has no durable worker owner")
        worker["last_steer_digest"] = action["request_digest"]
        worker["last_steer_at"] = iso_utc()
    else:
        raise LifecycleError("unsupported provider mutation result: {}".format(action_type))


def replay_pending(env, state):
    action = state.get("pending_action")
    if action is None:
        return False
    response = provider_call(env, "mutate", action)
    result = response.get("result")
    if not isinstance(result, dict) or result.get("idempotency_key") != action.get("idempotency_key"):
        raise LifecycleError("replayed provider mutation is not idempotently bound")
    apply_action_result(env, state, action, result)
    state["pending_action"] = None
    save_state(env, state)
    return True


def refresh_classifications(state, inventory, now=None):
    cloud = inventory_by_slot(inventory)
    for worker in state["workers"].values():
        classification, note = classify_worker(worker, cloud.get(worker["slot"]), now=now)
        worker["last_classification"] = classification
        worker["classification_note"] = note


def choose_free_slot(env, state, inventory):
    occupied = set(int(slot) for slot in state["workers"])
    occupied.update(worker["slot"] for worker in inventory["workers"])
    for slot in range(1, env["max_workers"] + 1):
        if slot not in occupied:
            return slot
    return None


def next_reconcile_action(env, state, inventory, now=None):
    now = now or now_utc()
    cloud = inventory_by_slot(inventory)
    conflicts = inventory.get("conflicts", [])
    if conflicts:
        raise LifecycleError("provider found same-fleet worker-name conflicts; unrelated resources were not adopted")

    # Released work is the only path to ordinary destruction. With queued work,
    # reset immediately; otherwise deallocate first and honor the short cooldown.
    waiting = queued_items(state)
    for slot_key in sorted(state["workers"], key=int):
        worker = state["workers"][slot_key]
        current = cloud.get(worker["slot"])
        classification, note = classify_worker(worker, current, now=now)
        worker["last_classification"] = classification
        worker["classification_note"] = note
        if not worker.get("release_proof"):
            continue
        if classification == "retained-for-investigation":
            continue
        if classification == "assigned":
            return make_action(env, "deallocate", worker=worker)
        if classification == "deallocated":
            started = parse_time(worker["cooldown_started_at"]) if worker.get("cooldown_started_at") else now
            elapsed = (now - started).total_seconds()
            if waiting or elapsed >= env["cooldown_seconds"]:
                return make_action(
                    env, "delete-compute", worker=worker,
                    release_proof_digest=worker["release_proof"]["proof_digest"],
                )
            continue
        if classification == "orphaned-safe-to-delete":
            return make_action(
                env, "reset", worker=worker,
                release_proof_digest=worker["release_proof"]["proof_digest"],
            )

    if not waiting:
        return None
    if active_count(state, inventory) >= env["max_workers"]:
        return None
    slot = choose_free_slot(env, state, inventory)
    if slot is None:
        return None
    item = waiting[0]
    admitted, reason, reservation = admission_result(env, state, inventory, slot, item)
    if not admitted:
        return {"type": "admission-refused", "reason": reason, "slot": slot, "reservation_usd": reservation}
    worker = create_worker_record(env, state, slot, item, reservation)
    state["workers"][str(slot)] = worker
    item["status"] = "assigning"
    shared_admission_digest = digest_value({
        "slot": worker["slot"], "sku": worker["sku"], "sku_family": worker["sku_family"],
        "assignment_generation": worker["assignment_generation"],
        "reservation_usd": reservation,
    })
    action = make_action(
        env, "create", worker=worker, item=item, reuse_retained=False,
        shared_admission_digest=shared_admission_digest,
    )
    return action


def reconcile(env, state, apply, confirm_subscription):
    if apply and confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    if apply and replay_pending(env, state):
        pass
    actions = []
    for _ in range(64):
        response = provider_call(env, "inventory")
        inventory = response["inventory"]
        state["last_metrics"] = metrics_from_inventory(inventory)
        refresh_classifications(state, inventory)
        action = next_reconcile_action(env, state, inventory)
        if action is None:
            save_state(env, state)
            return actions, inventory
        if action.get("type") == "admission-refused":
            actions.append(action)
            save_state(env, state)
            return actions, inventory
        actions.append(action)
        if not apply:
            # Dry planning may have allocated an in-memory worker record. Do not
            # persist or continue beyond the first mutation boundary.
            if action["type"] == "create":
                state["workers"].pop(str(action.get("slot")), None)
                key = request_key(action["request"]["task"], action["request"]["task_generation"])
                state["queue"][key]["status"] = "queued"
            return actions, inventory
        try:
            execute_action(env, state, action)
        except LifecycleError as exc:
            worker = state["workers"].get(str(action.get("slot")))
            record_refusal(state, worker, exc)
            save_state(env, state)
            raise
    raise LifecycleError("reconcile exceeded its bounded 64-action convergence allowance")


def release_receipt(state, path):
    proof = read_json(path, "worker release proof")
    if proof.get("schema") != RELEASE_SCHEMA:
        raise LifecycleError("worker release proof schema is not supported")
    supplied_digest = proof.get("proof_digest")
    unsigned = dict(proof)
    unsigned.pop("proof_digest", None)
    if supplied_digest != digest_value(unsigned):
        raise LifecycleError("worker release proof digest is not exact")
    for field in ("home_binding", "account_binding", "worktree_binding", "repository_binding"):
        require_binding(field, proof.get(field))
    for field in ("task", "task_generation", "assignment_generation", "repository_generation"):
        require_id(field, proof.get(field))
    authorities = proof.get("authorities")
    if not isinstance(authorities, dict) or set(authorities) != {
        "endpoint", "report", "landing", "account", "worktree",
    }:
        raise LifecycleError("release proof must contain every authoritative ordinary-owner receipt")
    for name, receipt in authorities.items():
        if not isinstance(receipt, dict) or receipt.get("schema") != AUTHORITY_SCHEMA:
            raise LifecycleError("{} authority receipt schema is not exact".format(name))
        supplied = receipt.get("receipt_digest")
        unsigned_receipt = dict(receipt)
        unsigned_receipt.pop("receipt_digest", None)
        if supplied != digest_value(unsigned_receipt):
            raise LifecycleError("{} authority receipt digest is not exact".format(name))
        if receipt.get("authority") != name or receipt.get("task") != proof.get("task"):
            raise LifecycleError("{} authority receipt task binding differs".format(name))
        if receipt.get("task_generation") != proof.get("task_generation"):
            raise LifecycleError("{} authority receipt generation differs".format(name))
        if receipt.get("assignment_generation") != proof.get("assignment_generation"):
            raise LifecycleError("{} authority receipt assignment differs".format(name))
        require_binding("{} authority evidence".format(name), receipt.get("evidence_digest"))
        if receipt.get("verdict") != "proved":
            raise LifecycleError("{} authority did not prove release safety".format(name))
    resources = proof.get("resources")
    if not isinstance(resources, dict) or set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise LifecycleError("worker release proof must bind every exact worker resource")
    for kind, identity in resources.items():
        if not isinstance(identity, dict) or not identity.get("id") or not identity.get("immutable_id"):
            raise LifecycleError("worker release proof {} identity is incomplete".format(kind))
    return proof


def verify_release_against_worker(proof, worker):
    bindings = worker["bindings"]
    checks = {
        "home_binding": bindings["home_binding"],
        "task": bindings["task"],
        "task_generation": bindings["task_generation"],
        "assignment_generation": worker["assignment_generation"],
        "account_binding": bindings["account_binding"],
        "worktree_binding": bindings["worktree_binding"],
        "repository_binding": bindings["repository_binding"],
        "repository_generation": bindings["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
    }
    for field, expected in checks.items():
        if proof.get(field) != expected:
            raise LifecycleError("worker release proof {} binding is not exact".format(field))


def proof_template(state, task, generation):
    key = request_key(task, generation)
    item = state["queue"].get(key)
    if item is None or item.get("status") != "assigned":
        raise LifecycleError("proof template requires one exact assigned queue item")
    worker = state["workers"].get(str(item.get("slot")))
    if worker is None or worker.get("queue_key") != key:
        raise LifecycleError("assigned queue item has no exact worker owner")
    proof = {
        "schema": RELEASE_SCHEMA,
        "home_binding": worker["bindings"]["home_binding"],
        "task": task,
        "task_generation": generation,
        "assignment_generation": worker["assignment_generation"],
        "account_binding": worker["bindings"]["account_binding"],
        "worktree_binding": worker["bindings"]["worktree_binding"],
        "repository_binding": worker["bindings"]["repository_binding"],
        "repository_generation": worker["bindings"]["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"],
        "resources": worker["resources"],
        "authorities": {
            name: {
                "schema": AUTHORITY_SCHEMA,
                "authority": name,
                "task": task,
                "task_generation": generation,
                "assignment_generation": worker["assignment_generation"],
                "verdict": "REPLACE_WITH_PROVED",
                "evidence_digest": "REPLACE_WITH_SHA256",
                "receipt_digest": "RECOMPUTE_FROM_ALL_OTHER_FIELDS",
            }
            for name in ("endpoint", "report", "landing", "account", "worktree")
        },
        "proof_digest": "RECOMPUTE_FROM_ALL_OTHER_FIELDS",
    }
    return proof


def status_projection(env, state, inventory=None):
    if inventory is None:
        metrics = state.get("last_metrics") or {}
        actual_active = sum(
            1 for worker in state["workers"].values()
            if worker.get("last_classification") == "assigned"
        )
        desired = min(
            sum(1 for item in state["queue"].values() if item.get("status") in ("queued", "assigned")),
            env["max_workers"],
        )
    else:
        metrics = metrics_from_inventory(inventory)
        actual_active = active_count(state, inventory)
        desired = desired_count(env, state, inventory)
    classes = {name: 0 for name in (
        "assigned", "clean-warm", "deallocated", "orphaned-safe-to-delete", "retained-for-investigation"
    )}
    assignment_generations = []
    retained_disks = 0
    for worker in state["workers"].values():
        classification = worker.get("last_classification", "retained-for-investigation")
        classes[classification] = classes.get(classification, 0) + 1
        assignment_generations.append(worker["assignment_generation"])
        if classification == "retained-for-investigation":
            retained_disks += sum(
                1 for kind in ("task-disk", "account-disk") if kind in worker.get("resources", {})
            )
    local_capacity = list(state.get("capacity_reservations", {}).values())
    specialized_queued = sum(1 for item in local_capacity if item.get("status") == "queued")
    specialized_reserved = sum(1 for item in local_capacity if item.get("status") == "reserved")
    specialized_reserved_vcpus = sum(
        item.get("vcpus", 0) for item in local_capacity if item.get("status") == "reserved"
    )
    regional_committed = None
    family_committed = {}
    if inventory is not None:
        try:
            commitments = capacity_commitments(state, inventory)
            regional_committed = commitments["regional_committed"]
            family_committed = commitments["family_committed"]
            specialized_reserved = len(commitments["specialized_reservations"])
            specialized_reserved_vcpus = sum(
                item["vcpus"] for item in commitments["specialized_reservations"].values()
            )
        except LifecycleError:
            pass
    hours = worker_seconds(state) / 3600.0
    return {
        "schema": "fm.worker-status/v1",
        "queue_depth": sum(1 for item in state["queue"].values() if item.get("status") != "complete"),
        "eligible_queue_depth": sum(1 for item in state["queue"].values() if item.get("status") == "queued" and item.get("eligible")),
        "desired_active_workers": desired,
        "actual_active_workers": actual_active,
        "classification_counts": classes,
        "assignment_generations": sorted(assignment_generations),
        "worker_hours": round(hours, 3),
        "worker_hour_planning_threshold": env["planning_hours"],
        "worker_hour_warning": hours >= env["planning_hours"],
        "actual_spend_usd": metrics.get("actual_usd"),
        "forecast_spend_usd": metrics.get("forecast_usd"),
        "policy_phase": env["policy_phase"],
        "active_admission_limit_usd": budget_limit(env),
        "planning_target_usd": env["steady_target_usd"],
        "commissioning_ceiling_usd": env["commissioning_ceiling_usd"],
        "regional_admission_ceiling_vcpus": REGIONAL_ADMISSION_CEILING_VCPUS,
        "regional_observed_used_vcpus": metrics.get("regional_used_vcpus"),
        "author_plan_vcpus": AUTHOR_PLAN_VCPUS,
        "specialized_shape_vcpus": SPECIALIZED_SHAPE_VCPUS,
        "specialized_active_vcpus": metrics.get("specialized_active_vcpus"),
        "specialized_queued_reservations": specialized_queued,
        "specialized_reserved_reservations": specialized_reserved,
        "specialized_reserved_vcpus": specialized_reserved_vcpus,
        "regional_observed_plus_reserved_vcpus": regional_committed,
        "family_observed_plus_reserved_vcpus": family_committed,
        "shared_headroom_vcpus": SHARED_HEADROOM_VCPUS,
        "idle_cooldown_seconds": env["cooldown_seconds"],
        "warm_idle_target": env["warm_idle"],
        "retained_disks": retained_disks,
        "cleanup_refusals": state["cleanup_refusals"][-10:],
    }


def print_status(status, json_output):
    if json_output:
        print(json.dumps(status, sort_keys=True, separators=(",", ":")))
        return
    print("queue: depth={} eligible={}".format(status["queue_depth"], status["eligible_queue_depth"]))
    print("workers: desired={} active={} classes={}".format(
        status["desired_active_workers"], status["actual_active_workers"],
        json.dumps(status["classification_counts"], sort_keys=True, separators=(",", ":")),
    ))
    print("assignments: {}".format(",".join(status["assignment_generations"]) or "none"))
    print("worker-hours: {:.3f}/{} warning={}".format(
        status["worker_hours"], status["worker_hour_planning_threshold"],
        str(status["worker_hour_warning"]).lower(),
    ))
    print("cost: actual={} forecast={} phase={} admission-limit={} planning-target={} commissioning-ceiling={}".format(
        status["actual_spend_usd"], status["forecast_spend_usd"], status["policy_phase"],
        status["active_admission_limit_usd"], status["planning_target_usd"],
        status["commissioning_ceiling_usd"],
    ))
    print("regional-capacity: used={} committed={}/{} author-plan={} specialized-active={} specialized-reserved={}/{} shared-headroom={}".format(
        status["regional_observed_used_vcpus"], status["regional_observed_plus_reserved_vcpus"],
        status["regional_admission_ceiling_vcpus"], status["author_plan_vcpus"],
        status["specialized_active_vcpus"], status["specialized_reserved_vcpus"],
        status["specialized_shape_vcpus"], status["shared_headroom_vcpus"],
    ))
    print("specialized-queue: queued={} reserved={}".format(
        status["specialized_queued_reservations"], status["specialized_reserved_reservations"],
    ))
    print("idle: cooldown={}s warm={} retained-disks={} cleanup-refusals={}".format(
        status["idle_cooldown_seconds"], status["warm_idle_target"],
        status["retained_disks"], len(status["cleanup_refusals"]),
    ))


def parser():
    top = argparse.ArgumentParser(description="Queue-driven provider-neutral elastic worker lifecycle")
    sub = top.add_subparsers(dest="command", required=True)
    request = sub.add_parser("request", help="enqueue one exact eligible author task")
    request.add_argument("--task", required=True)
    request.add_argument("--task-generation", required=True)
    request.add_argument("--home-binding", help=argparse.SUPPRESS)
    request.add_argument("--account-binding", help=argparse.SUPPRESS)
    request.add_argument("--worktree-binding", help=argparse.SUPPRESS)
    request.add_argument("--repository-binding", help=argparse.SUPPRESS)
    request.add_argument("--repository-generation", help=argparse.SUPPRESS)
    request.add_argument("--owner-kind", choices=("primary", "secondmate"), required=True)
    request.add_argument("--eligible", action="store_true")
    request.add_argument("--required", action="store_true", help="mark non-discretionary recovery/landing work")

    reconcile_parser = sub.add_parser("reconcile", help="plan or apply bounded convergence")
    reconcile_parser.add_argument("--apply", action="store_true")
    reconcile_parser.add_argument("--confirm-subscription")
    reconcile_parser.add_argument("--json", action="store_true")

    proof = sub.add_parser("proof-template", help="print the exact release-receipt skeleton")
    proof.add_argument("--task", required=True)
    proof.add_argument("--task-generation", required=True)

    capacity = sub.add_parser("capacity-reserve", help="queue and admit one specialized Azure reservation")
    capacity.add_argument("--reservation-id", required=True)
    capacity.add_argument("--fence-binding", required=True)
    capacity.add_argument("--role", choices=SPECIALIZED_WORKLOAD_ROLES, required=True)
    capacity.add_argument("--sku", required=True)
    capacity.add_argument("--sku-family", required=True)
    capacity.add_argument("--vcpus", type=int, required=True)
    capacity.add_argument("--amount-usd", type=float, required=True)
    capacity.add_argument("--required", action="store_true")
    capacity.add_argument("--confirm-subscription", required=True)

    shape = sub.add_parser(
        "capacity-reserve-shape",
        help="atomically queue and admit one complete specialized shape of exact constituents",
    )
    shape.add_argument("--shape-id", required=True)
    shape.add_argument("--fence-binding", required=True)
    shape.add_argument(
        "--constituent", action="append", required=True, metavar="SPEC",
        help="reservation-id=...,role=...,sku=...,sku-family=...,vcpus=...,amount-usd=...",
    )
    shape.add_argument("--confirm-subscription", required=True)

    capacity_release = sub.add_parser(
        "capacity-release", help="release one exact specialized reservation after zero-compute proof"
    )
    capacity_release.add_argument("--reservation-id", required=True)
    capacity_release.add_argument("--fence-binding", required=True)
    capacity_release.add_argument("--cleanup-receipt", required=True)
    capacity_release.add_argument("--confirm-subscription", required=True)

    execute = sub.add_parser("execute", help="run one exact private task command and collect its bound result")
    execute.add_argument("--task", required=True)
    execute.add_argument("--task-generation", required=True)
    execute.add_argument("--assignment-generation", required=True)
    execute.add_argument("--wall-seconds", type=int, default=3600)
    execute.add_argument("--confirm-execute", action="store_true")
    execute.add_argument("--confirm-subscription", required=True)
    execute.add_argument("argv", nargs=argparse.REMAINDER)

    receipt = sub.add_parser("authority-receipt", help="produce one exact ordinary-owner receipt bundle")
    receipt.add_argument("--task", required=True)
    receipt.add_argument("--task-generation", required=True)
    receipt.add_argument("--assignment-generation", required=True)
    receipt.add_argument("--output", required=True)

    release = sub.add_parser("release", help="accept exact ordinary lifecycle proofs")
    release.add_argument("--task", required=True)
    release.add_argument("--task-generation", required=True)
    release.add_argument("--proof-file", required=True)

    resume = sub.add_parser("resume", help="reattach exact retained dirty task capacity")
    resume.add_argument("--task", required=True)
    resume.add_argument("--task-generation", required=True)
    resume.add_argument("--repository-binding", required=True)
    resume.add_argument("--confirm-resume", action="store_true")
    resume.add_argument("--confirm-subscription", required=True)

    steer = sub.add_parser("steer", help="send one digest-bound request to the minimal guest supervisor")
    steer.add_argument("--task", required=True)
    steer.add_argument("--task-generation", required=True)
    steer.add_argument("--assignment-generation", required=True)
    steer.add_argument("--request-digest", required=True)
    steer.add_argument("--confirm-steer", action="store_true")
    steer.add_argument("--confirm-subscription", required=True)

    status = sub.add_parser("status", help="show bounded local lifecycle and cost evidence")
    status.add_argument("--live", action="store_true")
    status.add_argument("--json", action="store_true")

    sub.add_parser("acceptance-plan", help="print the isolated post-release acceptance checklist")
    return top


def authoritative_request_bindings(env, task, generation):
    require_id("task", task)
    require_id("task generation", generation)
    metadata = env["home"] / "state" / (task + ".meta")
    if metadata.is_symlink() or not metadata.is_file():
        raise LifecycleError("ordinary task metadata authority is absent")
    values = {}
    for line in metadata.read_text(encoding="utf-8").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    def exactly(key):
        entries = values.get(key, [])
        if len(entries) != 1 or not entries[0]:
            raise LifecycleError("ordinary task metadata {} identity is not exact".format(key))
        return entries[0]
    if exactly("generation_id") != generation:
        raise LifecycleError("ordinary task metadata generation differs")
    worktree = Path(exactly("worktree")).resolve()
    account_home = Path(exactly("account_home")).resolve()
    account_task = (values.get("account_task") or [task])[0]
    if account_task != task or not account_home.is_dir():
        raise LifecycleError("ordinary account lease authority differs from the task")
    try:
        top = Path(subprocess.check_output(
            ["git", "-C", str(worktree), "rev-parse", "--show-toplevel"], text=True
        ).strip()).resolve()
        git_dir = Path(subprocess.check_output(
            ["git", "-C", str(worktree), "rev-parse", "--git-dir"], text=True
        ).strip())
        if not git_dir.is_absolute():
            git_dir = (worktree / git_dir).resolve()
        head = subprocess.check_output(
            ["git", "-C", str(worktree), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as exc:
        raise LifecycleError("ordinary worktree authority is unreadable: {}".format(exc))
    if top != worktree:
        raise LifecycleError("ordinary worktree authority is not the exact repository root")
    recorded_git_identity = exactly("worktree_git_dir_identity")
    physical_identity = "{}:{}".format(os.stat(git_dir).st_dev, os.stat(git_dir).st_ino)
    if recorded_git_identity not in (physical_identity, digest_value({"git_dir": str(git_dir)})):
        raise LifecycleError("ordinary worktree Git-directory identity differs")
    return {
        "home_binding": env["home_binding"],
        "account_binding": digest_value({"task": task, "account_home": str(account_home)}),
        "worktree_binding": digest_value({"worktree": str(worktree), "git_dir": str(git_dir)}),
        "repository_binding": hashlib.sha256(head.encode("ascii")).hexdigest(),
        "repository_generation": head,
    }


def command_request(env, args):
    supplied = (
        args.home_binding, args.account_binding, args.worktree_binding,
        args.repository_binding, args.repository_generation,
    )
    if any(value is not None for value in supplied):
        test_provider = os.environ.get("FM_WORKER_PROVIDER_COMMAND", "")
        if (
            os.environ.get("FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS") != "1"
            or "provider.py" not in test_provider
            or not all(supplied)
        ):
            raise LifecycleError("caller-supplied worker bindings are unsupported; ordinary authorities own them")
        bindings = {
            "home_binding": require_binding("home binding", args.home_binding),
            "account_binding": require_binding("account binding", args.account_binding),
            "worktree_binding": require_binding("worktree binding", args.worktree_binding),
            "repository_binding": require_binding("repository binding", args.repository_binding),
            "repository_generation": require_id("repository generation", args.repository_generation),
        }
    else:
        bindings = authoritative_request_bindings(env, args.task, args.task_generation)
    item = {
        "schema": REQUEST_SCHEMA,
        "task": args.task,
        "task_generation": args.task_generation,
        **bindings,
        "owner_kind": args.owner_kind,
        "role": "author",
        "eligible": args.eligible,
        "discretionary": not args.required,
        "status": "queued",
        "enqueued_at": iso_utc(),
    }
    verify_request(item)
    key = request_key(item["task"], item["task_generation"])
    with controller_lock(env):
        state = load_state(env)
        existing = state["queue"].get(key)
        if existing is not None:
            identity_fields = (
                "schema", "task", "task_generation", "home_binding", "account_binding",
                "worktree_binding", "repository_binding", "repository_generation",
                "owner_kind", "role", "eligible", "discretionary",
            )
            if any(existing.get(field) != item.get(field) for field in identity_fields):
                raise LifecycleError("task generation already exists with different queue identity")
            print("request already exists with exact identity")
            return
        ensure_unique_bindings(state, item)
        state["queue"][key] = item
        save_state(env, state)
    print("queued {} generation {} for one isolated author worker".format(item["task"], item["task_generation"]))


def public_action(action):
    value = {
        key: action[key]
        for key in ("type", "slot", "sku", "sku_family", "reason", "reservation_usd")
        if key in action
    }
    if isinstance(action.get("bindings"), dict):
        value["assignment_generation"] = action["bindings"]["assignment_generation"]
    return value


def command_reconcile(env, args):
    with controller_lock(env):
        state = load_state(env)
        actions, inventory = reconcile(env, state, args.apply, args.confirm_subscription)
        status = status_projection(env, state, inventory)
    safe_actions = [public_action(action) for action in actions]
    output = {"actions": safe_actions, "status": status}
    if args.json:
        print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    else:
        for action in safe_actions:
            if action["type"] == "admission-refused":
                print("admission refused: {}".format(action["reason"]))
            else:
                print("{}: slot={} generation={}".format(
                    action["type"], action.get("slot"),
                    (action.get("bindings") or {}).get("assignment_generation", "n/a"),
                ))
        print_status(status, False)


def specialized_reservation_item(
    reservation_id, fence_binding, workload_role, sku, sku_family, vcpus,
    amount_usd, discretionary, shape_id=None,
):
    reservation_id = require_id("capacity reservation id", reservation_id)
    fence = require_binding("capacity reservation fence", fence_binding)
    if vcpus == 4:
        canonical_family = REVIEWED_SKU_FAMILY.get(sku)
    elif vcpus == 8:
        canonical_family = REVIEWED_CONTROL_SKU_FAMILY.get(sku)
    else:
        canonical_family = None
    if canonical_family is None or canonical_family.lower() != sku_family.lower():
        raise LifecycleError(
            "specialized reservation SKU, exact family, and reviewed four- or eight-vCPU shape must match together"
        )
    if not math.isfinite(amount_usd) or amount_usd <= 0:
        raise LifecycleError("specialized reservation cost must be finite and positive")
    item = {
        "schema": CAPACITY_RESERVATION_SCHEMA,
        "reservation_id": reservation_id,
        "fence_binding": fence,
        "role": "specialized",
        "workload_role": workload_role,
        "sku": sku,
        "sku_family": canonical_family,
        "vcpus": vcpus,
        "amount_usd": round(amount_usd, 6),
        "discretionary": discretionary,
        "status": "queued",
        "queued_at": iso_utc(),
        "reserved_at": None,
        "released_at": None,
        "cleanup_receipt": None,
        "last_refusal": None,
    }
    if shape_id is not None:
        item["shape_id"] = shape_id
    return item


def specialized_reservation_from_args(args):
    return specialized_reservation_item(
        args.reservation_id, args.fence_binding, args.role, args.sku,
        args.sku_family, args.vcpus, args.amount_usd, not args.required,
    )


def command_capacity_reserve(env, args):
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    candidate = specialized_reservation_from_args(args)
    reservation_id = candidate["reservation_id"]
    with controller_lock(env):
        state = load_state(env)
        existing = state["capacity_reservations"].get(reservation_id)
        readmission_id = None
        identity_fields = (
            "schema", "reservation_id", "fence_binding", "role", "workload_role", "sku",
            "sku_family", "vcpus", "discretionary",
        )
        if existing is not None:
            # A shape constituent is reserved by its parent with a cushioned
            # worst-case amount; the child's exact bound may re-admit at or
            # below that cushion without weakening the held accounting. A
            # reservation outside a shape still requires the exact amount.
            if existing.get("shape_id"):
                amount_exact = candidate["amount_usd"] <= existing.get("amount_usd", -1.0) + 1e-6
            else:
                amount_exact = math.isclose(
                    float(existing.get("amount_usd", -1.0)), float(candidate["amount_usd"]),
                    rel_tol=0.0, abs_tol=1e-6,
                )
            if any(existing.get(field) != candidate.get(field) for field in identity_fields) or not amount_exact:
                raise LifecycleError("capacity reservation id already has a different exact identity")
            if existing.get("status") == "released":
                raise LifecycleError("released capacity reservation identity cannot be reused")
            if existing.get("status") == "reserved":
                readmission_id = reservation_id
            candidate = existing
        else:
            state["capacity_reservations"][reservation_id] = candidate
            save_state(env, state)
        actual = None
        forecast = None
        try:
            inventory = provider_call(env, "inventory")["inventory"]
            state["last_metrics"] = metrics_from_inventory(inventory)
            actual = inventory["metrics"].get("actual_usd")
            forecast = inventory["metrics"].get("forecast_usd")
            admitted, reason = capacity_admission(
                env, state, inventory, candidate,
                ignore_reservation_id=readmission_id,
            )
        except LifecycleError as exc:
            admitted, reason = False, str(exc)
        if admitted:
            candidate["status"] = "reserved"
            candidate["reserved_at"] = candidate.get("reserved_at") or iso_utc()
            candidate["last_refusal"] = None
        else:
            # A reserved constituent of an atomically admitted shape keeps its
            # commitment: a child's lineage re-admission may observe transient
            # pressure, but its capacity is already counted and held.
            if not (readmission_id and candidate.get("shape_id")):
                candidate["status"] = "queued"
            candidate["last_refusal"] = {"at": iso_utc(), "reason": reason[:500]}
        save_state(env, state)
    print(json.dumps({
        "reservation_id": reservation_id,
        "status": candidate["status"],
        "reason": "" if admitted else reason,
        "actual_usd": actual,
        "forecast_usd": forecast,
        "admission_limit_usd": budget_limit(env),
    }, sort_keys=True, separators=(",", ":")))


def parse_shape_constituent(spec):
    fields = {}
    for part in spec.split(","):
        if "=" not in part:
            raise LifecycleError("shape constituent entries must be key=value pairs")
        key, value = part.split("=", 1)
        fields[key.strip()] = value.strip()
    required = {"reservation-id", "role", "sku", "sku-family", "vcpus", "amount-usd"}
    missing = sorted(required - set(fields))
    extra = sorted(set(fields) - required)
    if missing or extra:
        raise LifecycleError(
            "shape constituent fields are not exact (missing: {}; unexpected: {})".format(
                ",".join(missing) or "none", ",".join(extra) or "none"
            )
        )
    if fields["role"] not in SPECIALIZED_WORKLOAD_ROLES:
        raise LifecycleError("shape constituent role is not a reviewed specialized workload role")
    try:
        fields["vcpus"] = int(fields["vcpus"])
        fields["amount-usd"] = float(fields["amount-usd"])
    except ValueError:
        raise LifecycleError("shape constituent vcpus and amount-usd must be numeric")
    return fields


def command_capacity_reserve_shape(env, args):
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    shape_id = require_id("capacity shape id", args.shape_id)
    constituents = []
    seen_ids = set()
    for spec in args.constituent:
        fields = parse_shape_constituent(spec)
        candidate = specialized_reservation_item(
            fields["reservation-id"], args.fence_binding, fields["role"],
            fields["sku"], fields["sku-family"], fields["vcpus"],
            fields["amount-usd"], True, shape_id=shape_id,
        )
        if candidate["reservation_id"] in seen_ids:
            raise LifecycleError("shape constituent reservation ids must be distinct")
        seen_ids.add(candidate["reservation_id"])
        constituents.append(candidate)
    if not constituents:
        raise LifecycleError("a capacity shape needs at least one constituent")
    if sum(item["vcpus"] for item in constituents) > SPECIALIZED_SHAPE_VCPUS:
        raise LifecycleError("complete shape exceeds the shared 40-vCPU specialized envelope")
    identity_fields = (
        "schema", "reservation_id", "fence_binding", "role", "workload_role", "sku",
        "sku_family", "vcpus", "amount_usd", "discretionary", "shape_id",
    )
    with controller_lock(env):
        state = load_state(env)
        entries = []
        for candidate in constituents:
            existing = state["capacity_reservations"].get(candidate["reservation_id"])
            if existing is not None:
                if any(existing.get(field) != candidate.get(field) for field in identity_fields):
                    raise LifecycleError("capacity shape constituent already has a different exact identity")
                if existing.get("status") == "released":
                    raise LifecycleError("released capacity reservation identity cannot be reused")
                entries.append(existing)
            else:
                state["capacity_reservations"][candidate["reservation_id"]] = candidate
                entries.append(candidate)
        save_state(env, state)
        pending = [entry for entry in entries if entry.get("status") != "reserved"]
        actual = None
        forecast = None
        reason = ""
        admitted = True
        if pending:
            pending_ids = frozenset(entry["reservation_id"] for entry in pending)
            try:
                inventory = provider_call(env, "inventory")["inventory"]
                state["last_metrics"] = metrics_from_inventory(inventory)
                actual = inventory["metrics"].get("actual_usd")
                forecast = inventory["metrics"].get("forecast_usd")
                provisional = []
                for entry in pending:
                    admitted, reason = capacity_admission(
                        env, state, inventory, entry, provisional,
                        ignore_reservation_id=pending_ids,
                    )
                    if not admitted:
                        break
                    provisional.append(entry)
            except LifecycleError as exc:
                admitted, reason = False, str(exc)
            now = iso_utc()
            if admitted:
                for entry in pending:
                    entry["status"] = "reserved"
                    entry["reserved_at"] = entry.get("reserved_at") or now
                    entry["last_refusal"] = None
            else:
                # All-or-nothing: constituents that are not yet reserved stay queued;
                # already reserved constituents are never demoted by a shape retry.
                for entry in pending:
                    entry["status"] = "queued"
                    entry["last_refusal"] = {"at": now, "reason": reason[:500]}
        save_state(env, state)
        shape_status = "reserved" if all(
            entry.get("status") == "reserved" for entry in entries
        ) else "queued"
    print(json.dumps({
        "shape_id": shape_id,
        "status": shape_status,
        "reason": "" if shape_status == "reserved" else reason,
        "constituents": [
            {
                "reservation_id": entry["reservation_id"],
                "status": entry["status"],
                "sku": entry["sku"],
                "sku_family": entry["sku_family"],
                "vcpus": entry["vcpus"],
                "amount_usd": entry["amount_usd"],
            }
            for entry in entries
        ],
        "actual_usd": actual,
        "forecast_usd": forecast,
        "admission_limit_usd": budget_limit(env),
    }, sort_keys=True, separators=(",", ":")))


def command_capacity_release(env, args):
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    reservation_id = require_id("capacity reservation id", args.reservation_id)
    fence = require_binding("capacity reservation fence", args.fence_binding)
    receipt = require_binding("capacity cleanup receipt", args.cleanup_receipt)
    with controller_lock(env):
        state = load_state(env)
        reservation = state["capacity_reservations"].get(reservation_id)
        if reservation is None:
            raise LifecycleError("capacity release has no exact durable reservation")
        if reservation.get("fence_binding") != fence:
            raise LifecycleError("capacity release fence binding is not exact")
        if reservation.get("status") == "released":
            if reservation.get("cleanup_receipt") != receipt:
                raise LifecycleError("capacity reservation already has a different cleanup receipt")
            print("capacity reservation already released with exact zero-compute proof")
            return
        if reservation.get("status") not in ("queued", "reserved"):
            raise LifecycleError("capacity reservation status is not releasable")
        inventory = provider_call(env, "inventory")["inventory"]
        if any(
            item.get("reservation_id") == reservation_id and item.get("active") is True
            for item in inventory["capacity_reservations"]
        ):
            raise LifecycleError("capacity release did not prove provider-observed compute absence")
        reservation["status"] = "released"
        reservation["released_at"] = iso_utc()
        reservation["cleanup_receipt"] = receipt
        # Bound durable history without ever locking the controller out: keep
        # the newest 128 released records and drop older ones. Live queued and
        # reserved reservations are never pruned.
        released = sorted(
            (
                (item.get("released_at") or "", key)
                for key, item in state["capacity_reservations"].items()
                if isinstance(item, dict) and item.get("status") == "released"
            ),
        )
        for _, stale_key in released[:-128]:
            del state["capacity_reservations"][stale_key]
        save_state(env, state)
    print("specialized capacity reservation released after exact zero-compute proof")


def command_execute(env, args):
    if not args.confirm_execute:
        raise LifecycleError("--confirm-execute is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    argv = list(args.argv)
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv or len(argv) > 64 or any(not item or "\x00" in item or len(item) > 4096 for item in argv):
        raise LifecycleError("execution argv is empty or unbounded")
    if not 1 <= args.wall_seconds <= 6 * 60 * 60:
        raise LifecycleError("execution wall deadline must be between 1 and 21600 seconds")
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("execute requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("execute assignment generation is not exact")
        if worker.get("release_proof") is not None:
            raise LifecycleError("released work cannot execute")
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("execute refuses a non-assigned or ambiguous worker: {}".format(reason))
        request = {
            "schema": EXECUTION_SCHEMA,
            **worker["bindings"],
            "cloud_instance_id": worker["cloud_instance_id"],
            "argv": argv,
            "wall_seconds": args.wall_seconds,
        }
        request["request_digest"] = digest_value(request)
        existing = state["executions"].get(request["request_digest"])
        if existing is not None:
            print(json.dumps(existing, sort_keys=True, separators=(",", ":")))
            return
        action = make_action(
            env, "execute", worker=worker, request=request,
            request_digest=request["request_digest"],
        )
        execute_action(env, state, action)
        result = state["executions"][request["request_digest"]]
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def command_authority_receipt(env, args):
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        worker = state["workers"].get(str((item or {}).get("slot")))
        if item is None or worker is None or worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("authority receipt requires one exact assigned worker")
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False) as handle:
            json.dump(worker, handle, sort_keys=True, separators=(",", ":"))
            worker_path = handle.name
        try:
            result = subprocess.run([
                "python3", str(ROOT / "bin" / "fm-worker-authority.py"),
                "--home", str(env["home"]), "--task", args.task,
                "--task-generation", args.task_generation,
                "--assignment-generation", args.assignment_generation,
                "--worker-state", worker_path, "--output", args.output,
            ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=PROVIDER_TIMEOUT_SECONDS)
        finally:
            with contextlib.suppress(FileNotFoundError):
                Path(worker_path).unlink()
        if result.returncode != 0:
            detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
            raise LifecycleError("ordinary release authority refused: {}".format(detail))
    print("authoritative endpoint/report/landing/account/worktree receipts written")


def command_release(env, args):
    require_id("task", args.task)
    require_id("task generation", args.task_generation)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(args.task, args.task_generation)
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("release requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None:
            raise LifecycleError("release task has no exact durable worker owner")
        proof = release_receipt(state, args.proof_file)
        verify_release_against_worker(proof, worker)
        if worker.get("release_proof") is not None:
            if worker["release_proof"] != proof:
                raise LifecycleError("worker already has a different release proof")
            print("release proof already recorded with exact identity")
            return
        worker["release_proof"] = proof
        worker["released_at"] = iso_utc()
        worker["phase"] = "release-proved"
        item["status"] = "releasing"
        save_state(env, state)
    print("release proofs recorded; only exact idle capacity is now eligible for deallocation and reset")


def command_resume(env, args):
    if not args.confirm_resume:
        raise LifecycleError("--confirm-resume is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    require_binding("repository binding", args.repository_binding)
    with controller_lock(env):
        state = load_state(env)
        if state.get("pending_action") is not None:
            replay_pending(env, state)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("resume requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("queue_key") != key:
            raise LifecycleError("retained task has no exact durable worker owner")
        if worker.get("release_proof") is not None:
            raise LifecycleError("released work cannot use dirty-task resume")
        if worker.get("bindings", {}).get("repository_binding") != args.repository_binding:
            raise LifecycleError("retained repository/task generation proof is not exact")
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "retained-for-investigation" or cloud is None:
            raise LifecycleError("resume requires retained dirty disks and a missing worker VM: {}".format(reason))
        resources = cloud.get("resources") or {}
        if any(resources.get(kind) is not None for kind in ("vm", "nic", "os-disk")) or not resources.get("task-disk") or not resources.get("account-disk"):
            raise LifecycleError("resume requires exact retained task/account disks and no VM/NIC/OS disk")
        exact, identity_reason = resources_exact(worker, cloud, allow_missing_compute=True)
        if not exact:
            raise LifecycleError("retained disk identity proof failed: {}".format(identity_reason))
        for kind in ("vm", "nic", "os-disk"):
            worker.get("resources", {}).pop(kind, None)
        worker["cloud_instance_id"] = None
        previous_cloud_generation = worker["cloud_generation"]
        worker["cloud_generation"] += 1
        worker["phase"] = "resuming"
        action = make_action(
            env, "resume", worker=worker, item=item, reuse_retained=True,
            previous_cloud_generation=previous_cloud_generation,
            shared_admission_digest=digest_value({
                "slot": worker["slot"], "sku": worker["sku"], "sku_family": worker["sku_family"],
                "assignment_generation": worker["assignment_generation"],
                "reservation_usd": worker["reservation_usd"],
            }),
        )
        execute_action(env, state, action)
    print("replacement generation attached the exact retained task and account disks")


def command_steer(env, args):
    if not args.confirm_steer:
        raise LifecycleError("--confirm-steer is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    request_digest = require_binding("steer request digest", args.request_digest)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("steer requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker["assignment_generation"] != args.assignment_generation:
            raise LifecycleError("steer assignment generation is not exact")
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("steer refuses a non-assigned or ambiguous worker: {}".format(reason))
        action = make_action(env, "steer", worker=worker, request_digest=request_digest)
        execute_action(env, state, action)
    print("steer request digest delivered to the exact worker generation")


def command_status(env, args):
    with controller_lock(env):
        state = load_state(env)
        inventory = None
        if args.live:
            inventory = provider_call(env, "inventory")["inventory"]
            state["last_metrics"] = metrics_from_inventory(inventory)
            refresh_classifications(state, inventory)
            save_state(env, state)
        projection = status_projection(env, state, inventory)
    print_status(projection, args.json)


def command_proof_template(env, args):
    with controller_lock(env):
        state = load_state(env)
        proof = proof_template(
            state, require_id("task", args.task), require_id("task generation", args.task_generation)
        )
    print(json.dumps(proof, sort_keys=True, indent=2))


def acceptance_plan():
    print("""Post-release Azure acceptance (every leg also needs an unsafe positive control):
1. Start from zero and admit at least three parallel representative author tasks.
2. Finish one while another request waits; prove delete/reset precedes the next assignment generation.
3. Drain all work; prove active worker VMs reach zero and disposable VM/NIC/OS disks are absent.
4. Delete one unfinished worker VM; prove its exact task disk is retained and resumes only by explicit exact-generation recovery.
5. Restart after a submitted create; prove the idempotency key yields one cloud assignment.
6. Force actual and forecast budget pressure; prove new author admission stops and active work remains.
7. Probe public ingress plus account, worktree, browser, process, socket, cache, and cloud-identity residue across generations.
8. Use deliberately foreign tags/IDs, a stale result, a shared lease, a public rule, and planted residue as positive controls.
Do not run this acceptance until the reviewed foundation is released and the operator explicitly authorizes billable reconciliation.""")


def main(argv=None):
    args = parser().parse_args(argv)
    if args.command == "acceptance-plan":
        acceptance_plan()
        return 0
    env = environment()
    if args.command == "request":
        command_request(env, args)
    elif args.command == "capacity-reserve":
        command_capacity_reserve(env, args)
    elif args.command == "capacity-reserve-shape":
        command_capacity_reserve_shape(env, args)
    elif args.command == "capacity-release":
        command_capacity_release(env, args)
    elif args.command == "execute":
        command_execute(env, args)
    elif args.command == "authority-receipt":
        command_authority_receipt(env, args)
    elif args.command == "reconcile":
        command_reconcile(env, args)
    elif args.command == "proof-template":
        command_proof_template(env, args)
    elif args.command == "release":
        command_release(env, args)
    elif args.command == "resume":
        command_resume(env, args)
    elif args.command == "steer":
        command_steer(env, args)
    elif args.command == "status":
        command_status(env, args)
    else:
        raise LifecycleError("unknown lifecycle command")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except LifecycleError as exc:
        print("ELASTIC WORKER REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
