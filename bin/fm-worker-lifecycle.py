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
import copy
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import tempfile
import time
import uuid


ROOT = Path(__file__).resolve().parent.parent
AZURE_PROVIDER = ROOT / "bin" / "fm-azure-worker-provider.py"
WORKER_SUPERVISOR = ROOT / "bin" / "fm-worker-supervisor.py"
# The ONE implementation of "what is a Pi profile", "which upstream account is
# it", and "how is a single-profile account home written". Placement imports it
# rather than re-deriving any of the three: a second implementation of an
# account home is exactly how a credential stager and its remover once resolved
# different directories and leaked a credential.
PI_ACCOUNT_HOME_TOOL = ROOT / "bin" / "fm-pi-account-home.py"
CREDENTIAL_EXPIRY_TOOL = ROOT / "bin" / "fm-credential-expiry.py"
# Azure's hard worker shutdown is six hours.  Every canonical Pi profile must
# retain twice that headroom before the controller writes an assignment-private
# snapshot, so a guest never reaches the refresh path before the VM is dark.
CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS = 12 * 60 * 60
LEGACY_STATE_SCHEMA = "fm.worker-lifecycle/v1"
STATE_SCHEMA = "fm.worker-lifecycle/v2"
# The scalar pending_action slot this schema carried is superseded by the
# per-slot pending_actions map. The sentinel is deliberately a string an OLD
# binary's verify_state refuses ("pending provider action is malformed"), so a
# rollback cannot read None, plan fresh work, and blind-overwrite a live claim:
# it refuses loudly instead, cured by rolling forward.
LEGACY_PENDING_SENTINEL = "superseded-by-pending-actions"
REQUEST_SCHEMA = "fm.worker-request/v1"
EXECUTION_SCHEMA = "fm.worker-execution/v1"
EXECUTION_RESULT_SCHEMA = "fm.worker-execution-result/v1"
EXECUTION_TERMINAL_SCHEMA = "fm.worker-execution-terminal/v1"
EXECUTE_ABANDON_MARKER = "execute-abandon-action"
RELEASE_SCHEMA = "fm.worker-release/v2"
AUTHORITY_SCHEMA = "fm.worker-authority/v1"
CAPACITY_RESERVATION_SCHEMA = "fm.capacity-reservation/v1"
CAPACITY_FENCE_RETIREMENT_SCHEMA = "fm.capacity-fence-retirement/v1"
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
# The C3 requirement sentence is the number: a day's spend cannot quietly
# reach 100 dollars.
DEFAULT_DAILY_BOUND_USD = 100.0
PROVIDER_TIMEOUT_SECONDS = 300
# A create runs an ARM deployment (minutes, not seconds) and an execute blocks
# for the whole guest run. Bounding those at PROVIDER_TIMEOUT_SECONDS hangs the
# controller up while Azure carries on, leaving a live resource the controller
# never recorded.
# The provider's own worker-create step is allowed 3600s for the ARM
# deployment alone (run_pilot_create), and a create then runs the blocking
# bootstrap run command, the lifecycle children and two full inventory sweeps
# for tag convergence. A controller bound below that reproduces the very
# failure this exists to stop: hanging up while Azure carries on and leaving a
# live VM the controller never recorded.
# Must cover the provider's own ARM deployment budget PLUS its blocking
# bootstrap and lifecycle children. Kept above
# PILOT_CREATE_DEPLOY_TIMEOUT_SECONDS + CREATE_LIFECYCLE_BUDGET_SECONDS in
# bin/fm-azure-worker-provider.py; tests/fm-azure-pilot.test.sh checks it
# against those, because raising an inner bound without this one silently
# recreates the failure this constant exists to prevent.
PROVIDER_CREATE_TIMEOUT_SECONDS = 12600
# A steer is a control-plane action, but not a cheap one: the provider runs a
# full inventory sweep, then a blocking run-command invoke at its own 300s
# bound, then another sweep. Leaving it at PROVIDER_TIMEOUT_SECONDS makes the
# controller bound EQUAL to just the inner invoke, so an ordinary steer whose
# sweeps take any time at all is killed by the controller and reported as a
# missed deadline while the steer may already have landed in the guest.
PROVIDER_STEER_TIMEOUT_SECONDS = 1800
# Strictly larger than the provider's own client wait, because the provider
# runs a full inventory sweep, archive builds, uploads and SAS mints BEFORE the
# blocking call and another sweep plus a result upload AFTER it. A controller
# bound equal to the inner one kills the provider during collection and the
# task re-runs.
# Covers the provider's client wait PLUS everything it does around the blocking
# call (PRE_/POST_GUEST_CALL_BUDGET_SECONDS in the provider). Raising the client
# wait without raising this cuts the margin toward zero and the controller kills
# the provider mid-collection, which reads as a deadline miss for an execute
# that actually ran.
PROVIDER_GUEST_RUN_SLACK_SECONDS = 8400
MAX_PROVIDER_OUTPUT_BYTES = 2 * 1024 * 1024
# The compartment message lane's attachment ceiling. Must equal
# MESSAGE_ATTACH_MAX_BYTES in bin/fm-azure-worker-provider.py, which owns the
# actual size refusal; this copy only sizes the provider subprocess deadline.
# Kept in step by a test rather than by runtime coupling.
MESSAGE_ATTACH_MAX_BYTES = 256 * 1024 * 1024
# Every provider mutation type the claim contract covers. admission-refused is
# a bare planning verdict with no idempotency key, never claimed, never sent.
# message-put/message-collect are deliberately NOT here: the message lane is
# the one claim-exempt provider operation family (docs/azure-workers.md), and
# a message spec must never be storable as a pending claim.
ACTION_TYPES = frozenset({
    "create", "resume", "deallocate", "delete-compute", "reset", "execute", "steer",
})

REQUIRED_RESOURCE_KINDS = (
    "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
    "role-assignment", "state-container", "monitor-extension", "bootstrap-command",
    "task-command", "ttl-schedule", "global-reservation", "staging-request",
    "staging-result",
)
MUTABLE_PROVISIONING_CHILD_KINDS = frozenset({
    "monitor-extension", "bootstrap-command", "task-command", "ttl-schedule",
})
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


class ProviderIdentityRefused(LifecycleError):
    pass


class ProviderResultIdentityRefused(LifecycleError):
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


def _bounded_env_int(name, default, low, high):
    value = int(os.environ.get(name, str(default)))
    if value < low or value > high:
        raise LifecycleError("{} must be between {} and {}".format(name, low, high))
    return value


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
    daily_raw = os.environ.get("FM_AZURE_WORKER_DAILY_BOUND_USD")
    if daily_raw is None:
        daily_bound = DEFAULT_DAILY_BOUND_USD
    else:
        # An explicit zero, negative, or unparseable value refuses LOUDLY
        # instead of meaning "no bound": the C3 requirement is that a day's
        # spend cannot quietly reach 100 dollars, so the only way to run
        # unbounded is to not have this guard at all, which is not offered.
        try:
            daily_bound = float(daily_raw)
        except ValueError:
            daily_bound = float("nan")
        if not math.isfinite(daily_bound) or daily_bound <= 0:
            raise LifecycleError(
                "FM_AZURE_WORKER_DAILY_BOUND_USD must be a finite positive USD amount; "
                "unset means the default {} and 0 never means unbounded".format(
                    DEFAULT_DAILY_BOUND_USD))
    daily_override = (os.environ.get("FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE") or "").strip() or None
    try:
        idle_release = int(os.environ.get("FM_AZURE_WORKER_IDLE_RELEASE_SECONDS", "14400"))
    except ValueError:
        # Mirror the daily-bound parse: refuse through the loud ELASTIC WORKER
        # REFUSED lane, never a raw traceback.
        idle_release = -1
    if idle_release < 600 or idle_release > 604800:
        raise LifecycleError(
            "FM_AZURE_WORKER_IDLE_RELEASE_SECONDS must be an integer between 600 and 604800")
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
        "slot_lock_dir": state_dir / "slots",
        "max_workers": max_workers,
        "secondmate_max": _bounded_env_int("FM_AZURE_SECONDMATE_MAX", 2, 1, 4),
        "secondmate_child_max": _bounded_env_int("FM_SECONDMATE_CHILD_MAX", 4, 1, 8),
        "secondmate_child_total": _bounded_env_int("FM_SECONDMATE_CHILD_TOTAL", 16, 1, 32),
        "cooldown_seconds": cooldown,
        "warm_idle": warm_idle,
        "policy_phase": phase,
        "steady_target_usd": steady_target,
        "commissioning_ceiling_usd": commissioning_ceiling,
        "admission_hours": forecast_hours,
        "planning_hours": planning_hours,
        "daily_bound_usd": daily_bound,
        "daily_bound_override": daily_override,
        "idle_release_seconds": idle_release,
        "provider_argv": provider_argv,
        # Where placement writes assignment-private single-profile snapshots.
        # CONTROLLER-owned, under the same state directory as the document that
        # records each projection, and deliberately NOT a shared reviewer or
        # worker pool home.  Reusing one upstream profile therefore never makes
        # two assignments share writable storage.  The root follows FM_HOME so
        # a fixture home cannot write into a real one.
        "pi_account_root": Path(os.environ.get(
            "FM_PI_ACCOUNT_HOME_ROOT", str(state_dir / "accounts")
        )).expanduser(),
    }


_LOCK_STATE = {"held": False, "epoch": 0}


class FencedState(dict):
    """The durable document, stamped with the lock epoch and disk revision it
    was loaded under. A dict subclass serializes through json.dump unchanged;
    the stamps live on attributes, never in the document."""

    epoch = 0
    revision = 0


@contextlib.contextmanager
def controller_lock(env):
    # Re-entrant acquisition would deadlock on a second file description of the
    # same lock file; refusing it loudly also structurally prevents replaying
    # pending work from inside a hold.
    if _LOCK_STATE["held"]:
        raise LifecycleError("controller lock is already held by this process")
    env["state_dir"].mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(env["state_dir"], 0o700)
    with open(env["lock_path"], "a+", encoding="utf-8") as handle:
        os.chmod(env["lock_path"], 0o600)
        # NOTE: an execute holds this for its whole guest run, so concurrent
        # crewmates serialize here. Callers WAIT rather than fail; making the
        # loser error out was tried and reverted, because status, reconcile and
        # release would then start failing under ordinary contention. Real
        # concurrency needs the provider call to run outside this lock, which
        # is the next change in this series; the per-slot claim map, the load
        # fence and the revision CAS below are its durable groundwork.
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        _LOCK_STATE["held"] = True
        _LOCK_STATE["epoch"] += 1
        try:
            yield
        finally:
            _LOCK_STATE["held"] = False


class SlotBusy(LifecycleError):
    pass


class SlotLease:
    __slots__ = ("slot", "handle")

    def __init__(self, slot, handle):
        self.slot = slot
        self.handle = handle


@contextlib.contextmanager
def slot_lease(env, slot):
    """Exclusive claim on ONE slot's provider mutation, for the call's duration.

    LOCK_NB is hardcoded here so no call site can choose otherwise: exactly one
    lock in the system is ever waited on (the fleet lock), which makes deadlock
    impossible even though the apply phase takes the fleet lock while holding
    this one. The kernel drops it on process death, which is what makes a
    crashed owner's claim drainable at once; a durable lease would wedge the
    slot until manual repair, and a timed lease would have to exceed the
    longest provider deadline, which is not a lease.
    """
    slot = str(slot)
    if not slot.isdigit():
        raise LifecycleError("slot lease requires one exact decimal slot")
    env["slot_lock_dir"].mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(env["slot_lock_dir"], 0o700)
    path = env["slot_lock_dir"] / "slot-{}.lock".format(slot)
    with open(path, "a+", encoding="utf-8") as handle:
        os.chmod(path, 0o600)
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            raise SlotBusy("slot {} provider mutation is owned by a live process".format(slot))
        yield SlotLease(slot, handle)


def slot_lease_held(env, slot):
    """Liveness display only: whether some live process holds this slot's lease."""
    path = env["slot_lock_dir"] / "slot-{}.lock".format(str(slot))
    if not path.exists():
        return False
    with open(path, "a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return True
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        return False


def provider_mutate(env, action, lease):
    """The only path to a provider mutation: a live lease on the exact slot."""
    if not isinstance(lease, SlotLease) or lease.slot != str(action.get("slot")):
        raise LifecycleError("provider mutation is not covered by its slot's lease")
    response = _provider_call_raw(env, "mutate", action)
    result = response.get("result")
    if not isinstance(result, dict) or result.get("idempotency_key") != action["idempotency_key"]:
        raise LifecycleError("provider mutation result is not bound to the exact idempotency key")
    return result


def validate_abandon_execute_result(action, result):
    expected_task_command_id = (
        ((action.get("resources") or {}).get("task-command") or {}).get("id")
    )
    execution = result.get("execution") if isinstance(result, dict) else None
    if (
        not isinstance(result, dict)
        or result.get("idempotency_key") != action.get("idempotency_key")
        or result.get("action") != "abandon-execute"
        or not isinstance(execution, dict)
        or execution.get("schema") != EXECUTION_TERMINAL_SCHEMA
        or execution.get("request_digest") != action.get("request_digest")
        or execution.get("idempotency_key") != action.get("idempotency_key")
        or execution.get("disposition") != "provider-never-started-retired"
        or execution.get("provisioning_state") != "retired"
        or execution.get("task_command_id") != expected_task_command_id
        or execution.get("abandon_marker") != EXECUTE_ABANDON_MARKER
        or execution.get("retired") is not True
    ):
        raise LifecycleError("provider never-started execution retirement is not exact")
    worker = result.get("worker")
    resources = worker.get("resources") if isinstance(worker, dict) else None
    claimed_resources = action.get("resources") or {}
    expected_resource_kinds = set(claimed_resources)
    if (
        not isinstance(worker, dict)
        or worker.get("slot") != action.get("slot")
        or not isinstance(resources, dict)
        or set(resources) != expected_resource_kinds
        or (resources.get("task-command") or {}).get("id") != expected_task_command_id
        or "deallocated" not in str((resources.get("vm") or {}).get("power_state", "")).lower()
        or (resources.get("state-container") or {}).get("tags", {}).get(
            EXECUTE_ABANDON_MARKER
        ) != action.get("idempotency_key")
    ):
        raise LifecycleError("provider never-started retirement custody proof is incomplete")
    stable_immutable_kinds = expected_resource_kinds - MUTABLE_PROVISIONING_CHILD_KINDS - {
        "state-container", "staging-request", "staging-result",
    }
    for kind in expected_resource_kinds:
        returned = resources[kind]
        claimed = claimed_resources.get(kind) or {}
        if not isinstance(returned, dict) or returned.get("id") != claimed.get("id"):
            raise LifecycleError(
                "provider never-started retirement {} resource ID is not claimed".format(kind)
            )
        if (
            kind in stable_immutable_kinds
            and returned.get("immutable_id") != claimed.get("immutable_id")
        ):
            raise LifecycleError(
                "provider never-started retirement {} immutable identity differs".format(kind)
            )
    if (resources.get("vm") or {}).get("immutable_id") != action.get("cloud_instance_id"):
        raise LifecycleError("provider never-started retirement VM identity is not claimed")
    tag_worker = {
        "deployment_generation": action.get("deployment_generation"),
        "owner": action.get("owner"),
        "slot": action.get("slot"),
        "role": action.get("role", "author"),
        "bindings": action.get("bindings") or {},
    }
    required_tags = expected_tags(tag_worker)
    partial_tag_kinds = {
        "role-assignment", "state-container", "global-reservation",
        "staging-request", "staging-result",
    }
    for kind, returned in resources.items():
        tags = returned.get("tags") or {}
        for key, expected in required_tags.items():
            if kind in partial_tag_kinds and key not in tags:
                continue
            if tags.get(key) != expected:
                raise LifecycleError(
                    "provider never-started retirement {} assignment tag differs".format(kind)
                )
    return execution


def validate_durable_abandon_execute_worker(action, worker):
    if not isinstance(worker, dict):
        raise LifecycleError("durable worker for execute abandonment is absent")
    for field, expected in (
        ("slot", action.get("slot")),
        ("deployment_generation", action.get("deployment_generation")),
        ("owner", action.get("owner")),
        ("role", action.get("role", "author")),
        ("sku", action.get("sku")),
        ("sku_family", action.get("sku_family")),
        ("cloud_generation", action.get("cloud_generation")),
        ("cloud_instance_id", action.get("cloud_instance_id")),
    ):
        if worker.get(field) != expected:
            raise LifecycleError(
                "durable worker {} differs from the retired execute claim".format(field)
            )
    if (
        worker.get("assignment_generation")
        != (action.get("bindings") or {}).get("assignment_generation")
        or worker.get("bindings") != action.get("bindings")
    ):
        raise LifecycleError("durable worker bindings differ from the retired execute claim")
    durable_resources = worker.get("resources") or {}
    claimed_resources = action.get("resources") or {}
    if set(durable_resources) != set(claimed_resources):
        raise LifecycleError("durable worker resource set differs from the retired execute claim")
    for kind, claimed in claimed_resources.items():
        durable = durable_resources.get(kind) or {}
        if (
            durable.get("id") != (claimed or {}).get("id")
            or durable.get("immutable_id") != (claimed or {}).get("immutable_id")
        ):
            raise LifecycleError(
                "durable worker {} identity differs from the retired execute claim".format(kind)
            )


def provider_abandon_execute(env, action, lease):
    """Operator-only retirement of one exact crash-before-submit execute."""
    if not isinstance(lease, SlotLease) or lease.slot != str(action.get("slot")):
        raise LifecycleError("execute abandonment is not covered by its slot's lease")
    if action.get("type") != "execute":
        raise LifecycleError("execute abandonment requires an execute claim")
    response = _provider_call_raw(env, "abandon-execute", action)
    result = response.get("result")
    validate_abandon_execute_result(action, result)
    return result


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
        "retired_capacity_fences": {},
        "completed_worker_seconds": 0.0,
        "pending_action": LEGACY_PENDING_SENTINEL,
        "pending_actions": {},
        "revision": 0,
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
        or not isinstance(state.get("retired_capacity_fences"), dict)
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
    for fence, retirement in state["retired_capacity_fences"].items():
        if (
            not isinstance(retirement, dict)
            or retirement.get("schema") != CAPACITY_FENCE_RETIREMENT_SCHEMA
            or retirement.get("fence_binding") != fence
            or not isinstance(retirement.get("reservation_ids"), list)
            or not retirement.get("reservation_ids")
            or retirement.get("reservation_ids")
            != sorted(set(retirement.get("reservation_ids") or []))
            or len(retirement.get("reservation_ids") or []) > 256
            or not isinstance(retirement.get("retired_at"), str)
            or not retirement.get("retired_at")
        ):
            raise LifecycleError("durable specialized capacity fence retirement is malformed")
        require_binding("retired capacity fence", fence)
        require_binding(
            "capacity fence retirement receipt", retirement.get("retirement_receipt")
        )
        for reservation_id in retirement["reservation_ids"]:
            require_id("retired capacity reservation id", reservation_id)
    legacy = state.get("pending_action")
    if legacy is not None and legacy != LEGACY_PENDING_SENTINEL:
        # A dict here means load_state's migration did not run; anything else
        # is corruption. Both refuse rather than guess.
        raise LifecycleError("pending provider action is malformed")
    revision = state.get("revision")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
        raise LifecycleError("lifecycle state revision is malformed")
    pending = state.get("pending_actions")
    if not isinstance(pending, dict) or len(pending) > MAX_WORKERS:
        raise LifecycleError("pending provider action inventory is malformed")
    for slot_key, action in pending.items():
        # Bounded by MAX_WORKERS, never env max_workers: lowering
        # FM_AZURE_WORKER_MAX must not make an existing state file unloadable.
        # slot_key membership in workers is deliberately NOT required here:
        # enforcing it converts a recoverable wedge into a file that refuses
        # even `status`, and apply_action_result already raises on a missing
        # worker in every branch.
        if (
            not isinstance(action, dict)
            or not slot_key.isdigit()
            or not 1 <= int(slot_key) <= MAX_WORKERS
            or str(action.get("slot")) != slot_key
            or action.get("type") not in ACTION_TYPES
            or action.get("deployment_generation") != expected["deployment_generation"]
            or action.get("owner") != expected["owner"]
            or action_id(action) != action.get("idempotency_key")
        ):
            raise LifecycleError("pending provider action is malformed")
        require_binding("pending action idempotency key", action.get("idempotency_key"))


def load_state(env):
    try:
        state = read_json(env["state_path"], "lifecycle state")
    except LifecycleError as exc:
        if "is absent" not in str(exc):
            raise
        state = empty_state(env)
    if state.get("schema") == LEGACY_STATE_SCHEMA:
        # A v1 document has no fence-retirement authority to preserve. Upgrade
        # it in memory; the next locked save makes the v2 rollback fence
        # durable, after which a v1 binary refuses instead of reopening a
        # retired fence it does not understand.
        state["schema"] = STATE_SCHEMA
    state.setdefault("capacity_reservations", {})
    state.setdefault("retired_capacity_fences", {})
    state.setdefault("executions", {})
    state.setdefault("pending_actions", {})
    state.setdefault("revision", 0)
    for worker in state["workers"].values():
        if isinstance(worker, dict):
            worker.setdefault("placement", "azure")
    legacy = state.get("pending_action")
    if legacy is not None and legacy != LEGACY_PENDING_SENTINEL and not isinstance(legacy, dict):
        # The old binary refused this shape loudly; paving it over with the
        # sentinel would silently destroy whatever replay obligation the
        # corrupted bytes used to be. Refuse rather than guess.
        raise LifecycleError("pending provider action is malformed")
    if isinstance(legacy, dict):
        # apply_action_result has always addressed the worker by
        # action["slot"], so the action already carries its own key; nothing
        # is invented. Idempotent on every load; durable at the next save.
        slot = str(legacy.get("slot", ""))
        if not slot.isdigit():
            raise LifecycleError("legacy pending provider action carries no exact slot")
        held = state["pending_actions"].get(slot)
        if held is not None and held != legacy:
            raise LifecycleError(
                "legacy and per-slot pending actions disagree for slot {}".format(slot))
        state["pending_actions"][slot] = legacy
    state["pending_action"] = LEGACY_PENDING_SENTINEL
    verify_state(env, state)
    fenced = FencedState(state)
    fenced.epoch = _LOCK_STATE["epoch"]
    fenced.revision = int(state["revision"])
    return fenced


def save_state(env, state):
    if not isinstance(state, FencedState):
        raise LifecycleError("lifecycle state was not loaded through load_state")
    if not _LOCK_STATE["held"] or state.epoch != _LOCK_STATE["epoch"]:
        # The load fence: this object was loaded outside the lock hold that is
        # trying to commit it, so anything read from it may already be stale.
        raise LifecycleError("lifecycle state was loaded outside the committing lock hold")
    on_disk = 0
    try:
        current = read_json(env["state_path"], "lifecycle state")
        on_disk = int(current.get("revision", 0))
    except LifecycleError as exc:
        if "is absent" not in str(exc):
            raise
    if on_disk != state.revision:
        # Last-writer-wins over this document would not corrupt the file; it
        # would silently forget another writer's cloud resource identities and
        # re-admit a VM that exists and is billing. Refuse, naming both.
        raise LifecycleError(
            "lifecycle state revision moved from {} to {} since this load; reload and retry".format(
                state.revision, on_disk))
    state["revision"] = on_disk + 1
    state["updated_at"] = iso_utc()
    verify_state(env, state)
    save_json_atomic(env["state_path"], state)
    state.revision = state["revision"]


def request_key(task, generation):
    return "{}@{}".format(task, generation)


def verify_request(request):
    if request.get("schema") != REQUEST_SCHEMA:
        raise LifecycleError("worker request schema is not supported")
    for field in ("task", "task_generation", "repository_generation"):
        require_id(field, request.get(field))
    for field in ("home_binding", "account_binding", "worktree_binding", "repository_binding"):
        require_binding(field, request.get(field))
    role = request.get("role")
    if role not in ("author", "secondmate", "no-mistakes"):
        raise LifecycleError("worker request role must be author, secondmate, or no-mistakes")
    if request.get("owner_kind") not in ("primary", "secondmate"):
        raise LifecycleError("worker request owner_kind must be primary or secondmate")
    if role == "secondmate" and request.get("owner_kind") != "primary":
        # Depth one, by construction: a secondmate compartment is requested
        # only by the primary, so a secondmate owns author crewmates and never
        # another secondmate or a nested team.
        raise LifecycleError(
            "a secondmate compartment is requested only by the primary; "
            "secondmates own author crewmates, never another secondmate")
    if role == "no-mistakes" and request.get("owner_kind") != "primary":
        raise LifecycleError("a no-mistakes worker is requested only by the primary")
    parent = request.get("parent_task")
    parent_generation = request.get("parent_task_generation")
    if (parent is None) != (parent_generation is None):
        raise LifecycleError(
            "parent_task and parent_task_generation travel together or not at all")
    if parent is not None:
        # The parent pair marks a COMPARTMENT child specifically. A local
        # secondmate home still requests its own cloud crewmates with
        # owner_kind=secondmate and no parent (the documented lane in
        # docs/azure-workers.md), bounded by local policy rather than a
        # compartment budget; the compartment bridge always stamps the pair.
        if role != "author" or request.get("owner_kind") != "secondmate":
            raise LifecycleError(
                "parent_task is owned by secondmate-owned author requests only")
        require_id("parent_task", parent)
        require_id("parent_task_generation", parent_generation)
    task_home = request.get("task_home")
    if task_home is not None:
        if parent is None or role != "author" or request.get("owner_kind") != "secondmate":
            raise LifecycleError(
                "task home is owned by compartment child requests only")
        if not isinstance(task_home, str) or not task_home.startswith("/") or len(task_home) > 4096:
            raise LifecycleError("worker request task home must be one absolute path")
    pool_home = request.get("account_pool_home")
    if pool_home is not None and (
        not isinstance(pool_home, str) or not pool_home.startswith("/")
        or len(pool_home) > 4096
    ):
        raise LifecycleError("worker request account pool home must be one absolute path")
    profile = request.get("account_profile")
    account_home = request.get("account_home")
    projection_binding = request.get("account_projection_binding")
    if (profile is None) != (account_home is None) or (
        profile is None and projection_binding is not None
    ):
        raise LifecycleError(
            "account_profile, account_home, and account_projection_binding travel together")
    if profile is not None:
        require_id("account_profile", profile)
        require_binding("account_projection_binding", projection_binding)
        if not isinstance(account_home, str) or not account_home.startswith("/") \
                or len(account_home) > 4096:
            raise LifecycleError("worker request account home must be one absolute path")
    if request.get("eligible") is not True:
        raise LifecycleError("worker request must be explicitly eligible")


def active_queue_items(state):
    return [item for item in state["queue"].values() if item.get("status") != "complete"]


_PI_PROJECTION = {}


def pi_projection():
    """The projection tool, loaded as a module, not re-implemented.

    Placement needs three things from it and takes all three from the one
    implementation: `read_pool` (what profiles exist and are they shaped like a
    credential), `account_digest` (which upstream account is this, by digest
    and never by token material), and `write_home`/`prepare_root` (how a
    single-profile account home is written, owner-only, atomically).
    """
    module = _PI_PROJECTION.get("module")
    if module is not None:
        return module
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "fm_pi_account_home", str(PI_ACCOUNT_HOME_TOOL))
    if spec is None or spec.loader is None:
        raise LifecycleError(
            "the Pi account-home projection tool is unavailable at {}".format(
                PI_ACCOUNT_HOME_TOOL))
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # noqa: BLE001 - any import failure is a refusal
        raise LifecycleError(
            "the Pi account-home projection tool could not be loaded from {}: {}".format(
                PI_ACCOUNT_HOME_TOOL, type(exc).__name__))
    _PI_PROJECTION["module"] = module
    return module


_CREDENTIAL_EXPIRY = {}


def credential_expiry():
    """Load the credential-expiry owner without copying its token semantics."""
    module = _CREDENTIAL_EXPIRY.get("module")
    if module is not None:
        return module
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "fm_credential_expiry", str(CREDENTIAL_EXPIRY_TOOL))
    if spec is None or spec.loader is None:
        raise LifecycleError(
            "the credential-expiry tool is unavailable at {}".format(
                CREDENTIAL_EXPIRY_TOOL))
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # noqa: BLE001 - any import failure is a refusal
        raise LifecycleError(
            "the credential-expiry tool could not be loaded from {}: {}".format(
                CREDENTIAL_EXPIRY_TOOL, type(exc).__name__))
    _CREDENTIAL_EXPIRY["module"] = module
    return module


def placement_account_binding(account_digest):
    """The reusable, non-secret identity of one upstream Pi account.

    The binding stays stable and travels through queue, worker, Azure, release,
    and status records, but it is no longer an exclusion key.  Multiple
    assignments may use immutable snapshots of the same canonical profile
    while retaining this exact provider-quota identity.
    """
    return digest_value({"provider": "pi", "upstream_account": account_digest})


def leased_placement_accounts(state, pool_home=None):
    """Active load per reusable profile/account pair, derived from the queue.

    The compatibility name remains because callers already know it, but the
    result is load evidence rather than an exclusive lease set.  Pool identity
    is part of the key so equal local slot names in separate canonical homes do
    not distort each other's selection.
    """
    loads = {}
    for item in state["queue"].values():
        if item.get("status") == "complete":
            continue
        item_pool = item.get("account_pool_home")
        profile = item.get("account_profile")
        binding = item.get("account_binding")
        if pool_home is not None and item_pool != str(pool_home):
            continue
        if not all(isinstance(value, str) and value for value in (
            item_pool, profile, binding,
        )):
            continue
        key = (item_pool, profile, binding)
        load = loads.setdefault(key, {"active": 0, "tasks": []})
        load["active"] += 1
        load["tasks"].append(item.get("task"))
    return loads


def placement_projection_binding(item, profile, account_binding):
    """Stable assignment-private writable-home identity for one request."""
    return digest_value({
        "provider": "pi",
        "home_binding": item["home_binding"],
        "task": item["task"],
        "task_generation": item["task_generation"],
        "account_pool_home": item["account_pool_home"],
        "account_profile": profile,
        "account_binding": account_binding,
    })


def select_placement_account(env, state, pool_home, item):
    """Snapshot the least-loaded usable Pi profile for one placement.

    Selection and queue ownership remain inside one controller lock hold, and
    projection begins only after that owner is durable.  Reusable upstream
    bindings are load evidence, while the writable projection is keyed by the
    exact task generation and selected
    profile so no two assignments ever share a home.
    """
    projection = pi_projection()
    expiry = credential_expiry()
    pool_home = str(pool_home)
    pool_file = Path(pool_home) / "auth.json"
    try:
        pool = projection.read_pool(pool_file)
    except projection.ProjectionError as exc:
        raise LifecycleError(
            "provider-account placement pool is unusable: {}; a worker is never "
            "placed on an unidentified account".format(exc))
    if not pool:
        raise LifecycleError(
            "provider-account placement pool at {} declares no profile".format(pool_file))

    loads = leased_placement_accounts(state, pool_home)
    deadline = time.time() + CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS
    candidates = []
    faults = {}
    for name in sorted(pool):
        entry = pool[name]
        entry_faults = projection.entry_faults(entry)
        if entry_faults:
            faults[name] = "; ".join(entry_faults)
            continue
        digest = projection.account_digest(entry)
        if digest == "none":
            faults[name] = "exposes no upstream account identity"
            continue
        # The expiry owner interprets the credential in memory BEFORE any
        # assignment snapshot is written.  A guest cannot refresh the
        # canonical profile, and a token that would need refresh inside the
        # worker lifetime never reaches a projection at all.
        shaped = {projection.CONSUMER_KEY: entry}
        if not expiry.credential_usable_through(
            shaped, harness="pi", deadline=deadline,
        ):
            faults[name] = "lacks twelve hours of access-token headroom"
            continue
        binding = placement_account_binding(digest)
        active = loads.get((pool_home, name, binding), {}).get("active", 0)
        candidates.append((active, name, binding))
    if not candidates:
        raise LifecycleError(
            "provider-account placement pool at {} holds no usable profile ({})".format(
                pool_file,
                ", ".join("{}: {}".format(name, faults[name]) for name in sorted(faults))))

    # Least active first, then the stable local profile label, then the stable
    # upstream digest.  Every usable profile is represented before any is
    # reused, and equal loads converge on the same choice after a restart.
    _, name, binding = min(candidates)
    projection_binding = placement_projection_binding(item, name, binding)
    root = Path(env["pi_account_root"]).resolve()
    destination = root / projection_binding
    for active in state["queue"].values():
        if active.get("status") == "complete":
            continue
        if (
            active.get("account_projection_binding") == projection_binding
            or active.get("account_home") == str(destination)
        ):
            raise LifecycleError(
                "assignment-private provider projection is already owned by {}".format(
                    active.get("task") or "an unnamed task"))
    return {
        "account_profile": name,
        "account_home": str(destination),
        "account_binding": binding,
        "account_projection_binding": projection_binding,
    }


def write_placement_snapshot(env, item):
    """Write or replay one queue-owned canonical-profile snapshot."""
    projection = pi_projection()
    expiry = credential_expiry()
    pool_home = item.get("account_pool_home")
    profile = item.get("account_profile")
    if not isinstance(pool_home, str) or not isinstance(profile, str):
        raise LifecycleError("provider-account snapshot source identity is unavailable")
    pool_file = Path(pool_home) / "auth.json"
    try:
        pool = projection.read_pool(pool_file)
    except projection.ProjectionError as exc:
        raise LifecycleError(
            "provider-account snapshot source is unusable: {}".format(exc))
    entry = pool.get(profile)
    if entry is None or projection.entry_faults(entry):
        raise LifecycleError(
            "selected Pi profile {} is no longer usable for its snapshot".format(profile))
    account_digest = projection.account_digest(entry)
    if placement_account_binding(account_digest) != item.get("account_binding"):
        raise LifecycleError(
            "selected Pi profile {} changed upstream identity before snapshot".format(profile))
    if not expiry.credential_usable_through(
        {projection.CONSUMER_KEY: entry}, harness="pi",
        deadline=time.time() + CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS,
    ):
        raise LifecycleError(
            "selected Pi profile {} lacks twelve hours of access-token headroom".format(
                profile))
    projected = placement_projection_path(env, item)
    if projected is None:
        raise LifecycleError("assignment-private provider projection identity is unavailable")
    root, destination = projected
    try:
        projection.prepare_root(root)
        credential = projection.write_home(destination, entry)
    except projection.ProjectionError as exc:
        raise LifecycleError(
            "Pi profile {} could not be snapshotted into its assignment-private home: {}".format(
                profile, exc))
    except OSError as exc:
        raise LifecycleError(
            "Pi profile {} could not be snapshotted into its assignment-private home: {}".format(
                profile, exc.strerror or exc))
    if str(Path(credential).parent) != item["account_home"]:
        raise LifecycleError("provider-account snapshot destination changed identity")


def ensure_unique_bindings(state, candidate, ignore_key=None):
    """Refuse shared writable custody while allowing reusable account identity."""
    for key, item in state["queue"].items():
        if key == ignore_key or item.get("status") == "complete":
            continue
        candidate_projection = candidate.get("account_projection_binding")
        if candidate_projection is not None and (
            item.get("account_projection_binding") == candidate_projection
            or item.get("account_home") == candidate.get("account_home")
        ):
            raise LifecycleError(
                "assignment-private provider projection is already owned by another "
                "queued or active task")
        if item.get("worktree_binding") == candidate["worktree_binding"]:
            raise LifecycleError(
                "writable worktree binding is already owned by another queued or active task")


def placement_projection_path(env, item):
    """Return one new-style projection path, never a legacy shared home."""
    binding = item.get("account_projection_binding")
    account_home = item.get("account_home")
    if binding is None:
        # Existing assignments created before reusable snapshots may point at a
        # canonical single-profile home or an account-keyed projection.  This
        # release must never infer ownership of either and delete it.
        return None
    require_binding("account projection binding", binding)
    root = Path(env["pi_account_root"]).resolve()
    expected = root / binding
    if account_home != str(expected):
        raise LifecycleError(
            "assignment-private provider projection path differs from its binding")
    return root, expected


def cleanup_placement_projection(env, item):
    """Remove exactly one assignment-private snapshot without traversing peers."""
    projected = placement_projection_path(env, item)
    if projected is None:
        return
    root, destination = projected
    try:
        root_info = root.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise LifecycleError(
            "provider projection root is unreadable during cleanup: {}".format(
                exc.strerror or exc))
    if not stat.S_ISDIR(root_info.st_mode) or root.is_symlink():
        raise LifecycleError("provider projection root changed identity during cleanup")
    try:
        destination_info = destination.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise LifecycleError(
            "assignment-private provider projection is unreadable during cleanup: {}".format(
                exc.strerror or exc))
    if (
        not stat.S_ISDIR(destination_info.st_mode)
        or destination.is_symlink()
        or destination_info.st_uid != os.geteuid()
        or destination_info.st_mode & (stat.S_IWGRP | stat.S_IWOTH)
    ):
        raise LifecycleError(
            "assignment-private provider projection changed identity during cleanup")
    try:
        entries = list(os.scandir(destination))
    except OSError as exc:
        raise LifecycleError(
            "assignment-private provider projection cannot be inventoried: {}".format(
                exc.strerror or exc))
    if len(entries) > 8:
        raise LifecycleError(
            "assignment-private provider projection holds unexpected cleanup state")
    for entry in entries:
        if entry.name != "auth.json" and not (
            entry.name.startswith(".auth-") and entry.name.endswith(".tmp")
        ):
            raise LifecycleError(
                "assignment-private provider projection holds unexpected cleanup state")
        info = entry.stat(follow_symlinks=False)
        if (
            not stat.S_ISREG(info.st_mode)
            or stat.S_ISLNK(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & (stat.S_IRWXG | stat.S_IRWXO)
        ):
            raise LifecycleError(
                "assignment-private provider credential changed identity during cleanup")
    try:
        for entry in entries:
            os.unlink(entry.path)
        os.rmdir(destination)
        descriptor = os.open(str(root), os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError as exc:
        raise LifecycleError(
            "assignment-private provider projection cleanup failed: {}".format(
                exc.strerror or exc))


def provider_action_timeout(action):
    """How long the provider subprocess may take for one action."""
    if not isinstance(action, dict):
        return PROVIDER_TIMEOUT_SECONDS
    if action.get("type") == "execute":
        wall = (action.get("request") or {}).get("wall_seconds")
        if isinstance(wall, int) and not isinstance(wall, bool) and wall > 0:
            return wall + PROVIDER_GUEST_RUN_SLACK_SECONDS
        return PROVIDER_GUEST_RUN_SLACK_SECONDS
    if action.get("type") in ("create", "resume", "reset", "delete-compute", "deallocate"):
        return PROVIDER_CREATE_TIMEOUT_SECONDS
    if action.get("type") == "steer":
        return PROVIDER_STEER_TIMEOUT_SECONDS
    message_bytes = action.get("message_bytes")
    if isinstance(message_bytes, int) and not isinstance(message_bytes, bool) and message_bytes >= 0:
        # Message-lane blob transfers get a bound proportional to their
        # declared size, mirroring the provider's own per-transfer az bounds;
        # a 256 MiB attachment cannot move inside the ordinary bound.
        return PROVIDER_TIMEOUT_SECONDS + message_bytes // (256 * 1024)
    return PROVIDER_TIMEOUT_SECONDS


def provider_call(env, operation, action=None):
    if operation == "mutate":
        # The only mutate path is provider_mutate, which requires a live slot
        # lease; a bare mutate here is a call site the lock discipline missed.
        raise LifecycleError("provider mutations go through provider_mutate with a slot lease")
    return _provider_call_raw(env, operation, action)


def _provider_call_raw(env, operation, action=None):
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
            timeout=provider_action_timeout(action),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LifecycleError("provider operation is unavailable or exceeded its bounded deadline: {}".format(exc))
    if len(result.stdout) > MAX_PROVIDER_OUTPUT_BYTES or len(result.stderr) > MAX_PROVIDER_OUTPUT_BYTES:
        raise LifecycleError("provider response exceeded its bounded output allowance")
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        if result.returncode == 3 and detail.startswith(
            "AZURE WORKER PROVIDER REFUSED-IDENTITY:"
        ):
            raise ProviderIdentityRefused(detail)
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
    if worker.get("role") == "secondmate":
        # A compartment VM must never be classified (by the cloud's own
        # metadata) as a one-task crewmate: those tags would be a lie, and the
        # exactness machinery compares them exactly.
        return {
            "workload": "firstmate",
            "firstmate-role": "secondmate-compartment",
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
            "agent-capacity": "one-home-scoped-secondmate",
            "nested-team": "forbidden",
            "child-launcher": "absent",
            "browser-profile": "forbidden",
        }
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
        if prior is not None and current.get("id") != prior.get("id"):
            return False, "{} resource ID changed".format(kind)
        # Compute-child provisioningState changes during ordinary VM lifecycle
        # transitions. Its stable ARM ID remains fenced above; the provider
        # independently checks exact VM attachment, tags, and readiness where
        # the requested operation needs a ready child.
        # Azure Blob container metadata writes change the container ETag. The
        # provider's canonical inventory therefore uses the exact container
        # ARM path as its stable identity. Accept a worker recorded by the
        # older ETag-bearing shape only when the current stable identity and
        # both resource paths are that same exact ARM path.
        legacy_state_container = (
            kind == "state-container"
            and current.get("immutable_id") == current.get("id")
            and prior is not None
            and prior.get("id") == current.get("id")
        )
        if (
            prior is not None
            and kind not in MUTABLE_PROVISIONING_CHILD_KINDS
            and kind not in ("staging-request", "staging-result")
            and current.get("immutable_id") != prior.get("immutable_id")
            and not legacy_state_container
        ):
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


def utc_day(now=None):
    return (now or now_utc()).strftime("%Y-%m-%d")


def roll_daily_baseline(state, actual, now=None):
    """Snapshot the day's starting spend on the first observation of a new UTC day.

    Cost Management reports month-to-date actual, never an intraday figure, so
    the honest computable day spend is (current actual - the actual recorded
    when this controller first observed the day). The baseline is durable in
    controller state and rolls only under the caller's fleet-lock hold. The UTC
    month boundary is also a UTC day boundary, so the month-to-date reset can
    never make same-day spend negative; a mid-day downward ACM revision is
    clamped by the reader instead. Returns the current baseline record, or
    None when the actual is unreadable (the bound check then fails closed)."""
    if isinstance(actual, bool) or not isinstance(actual, (int, float)):
        return None
    day = utc_day(now)
    baseline = state.get("daily_cost_baseline")
    if not isinstance(baseline, dict) or baseline.get("utc_day") != day:
        baseline = {"utc_day": day, "actual_usd_at_day_start": float(actual)}
        state["daily_cost_baseline"] = baseline
    return baseline


def daily_spend_evidence(state, actual, now=None):
    """(utc day, recorded day spend or None). Rolls the baseline as a side effect."""
    day = utc_day(now)
    baseline = roll_daily_baseline(state, actual, now)
    if baseline is None:
        return day, None
    return day, max(0.0, float(actual) - float(baseline["actual_usd_at_day_start"]))


def daily_bound_refusal(env, state, actual, now=None):
    """The C3 daily spend bound over NEW spend commitments only.

    Returns (refusal_or_None, override_day_or_None). A refusal blocks exactly
    the lanes that commit new money: the compute-creating and compute-resuming
    provider actions (create, resume) and NEW specialized reservation
    admissions (capacity-reserve, capacity-reserve-shape) - the disposable
    runner performs those automatically, so an ungated reserve lane could
    quietly burn past the bound with no human anywhere. Releases (including
    capacity-release), deallocates, compute deletions, resets, and the
    claim-exempt message lane are never routed through this check: winding
    down must never be blocked by the very guard that exists to stop spend.
    An execute on an already-assigned worker stays allowed - the capacity is
    already held and billing; refusing its work would burn the same money for
    nothing - and for the same reason a lineage re-admission of an
    already-reserved shape constituent is already-held accounting, not new
    spend, and skips this gate.

    Honesty note: Cost Management actual lags hours, so this bound is a
    backstop on RECORDED spend, not a real-time meter. The same-day protectors
    ahead of it are the per-mutation cumulative admission and the idle
    deallocate path; this bound guarantees the day cannot keep admitting new
    compute once the recorded number crosses it.

    Callers hold the fleet lock and must save state afterwards when they keep
    going: this check rolls the daily baseline. It never records override use
    itself - only record_daily_override_use does, AFTER the admission decision,
    so status can never claim an override "use" on a day where cumulative
    admission then refused anyway.
    """
    day, spend = daily_spend_evidence(state, actual, now)
    bound = env["daily_bound_usd"]
    if spend is None:
        return (
            "daily spend bound: shared actual spend is unreadable, so day {} spend "
            "cannot be proven under the {:.2f} USD daily bound; new compute is refused".format(
                day, bound),
            None,
        )
    if spend < bound:
        return None, None
    override = env["daily_bound_override"]
    if override == day:
        return None, day
    if override:
        hint = "FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} does not name today".format(override)
    else:
        hint = (
            "set FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} to admit past the bound "
            "for this day only".format(day))
    return (
        "daily spend bound: day {} recorded spend {:.2f} USD reached the {:.2f} USD "
        "daily bound; new compute and reservations (create/resume/capacity-reserve) "
        "are refused, wind-down stays allowed; {}".format(day, spend, bound, hint),
        None,
    )


def record_daily_override_use(env, state, actual, override_day, now=None):
    """Durably record that the exact-day override actually ADMITTED something.

    Called only after the admission decision went the override's way: recording
    at check time let status claim the override was "used" on a day where
    cumulative admission then refused the candidate anyway. Caller holds the
    fleet lock and saves state.
    """
    day, spend = daily_spend_evidence(state, actual, now)
    state["daily_bound_override_used"] = {
        "utc_day": override_day,
        "at": iso_utc(now),
        "recorded_day_spend_usd": round(spend, 6) if spend is not None else None,
        "bound_usd": env["daily_bound_usd"],
    }


def idle_deallocate_due(env, state, worker, cloud, now=None):
    """True when an assigned worker's task provably ended long enough ago.

    Provable signals only: an execute in flight holds the slot's
    pending_actions claim (the planner already skips claimed slots before this
    runs), and last_execution_at is stamped only when a durably applied
    execution result exists in state["executions"]. A worker that never
    executed is NOT idle-deallocated here - nothing in controller state proves
    its task ended - and its per-VM TTL schedule remains the backstop, exactly
    as it was for wkr-04.

    Recency counts EVERY durable activity stamp the worker record carries,
    not just executions: a worker steered minutes ago is being actively
    driven, and deallocating it would be operationally terminal for the
    assignment (execute refuses deallocated compute; resume needs the VM
    absent; release is the only exit).
    """
    now = now or now_utc()
    vm = ((cloud or {}).get("resources") or {}).get("vm")
    if vm is None or "deallocated" in str(vm.get("power_state", "")).lower():
        return False
    item = state["queue"].get(worker.get("queue_key"))
    if item is None or item.get("status") != "assigned":
        return False
    if not worker.get("last_execution_at"):
        return False
    newest = None
    for field in ("last_execution_at", "last_steer_at"):
        value = worker.get(field)
        if not value:
            continue
        parsed = parse_time(value)
        if newest is None or parsed > newest:
            newest = parsed
    return (now - newest).total_seconds() >= env["idle_release_seconds"]


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
        if current is not None:
            if local.get("shape_id"):
                # A shape constituent is held locally at its parent's cushioned
                # worst-case amount while the provider registration carries the
                # child's exact bound; within the cushion the identities agree
                # (the same rule the re-admission path applies). Exact equality
                # here poisoned every admission while any shard ran (generation
                # 044 ground truth: a one-dollar cushion refused all retries).
                amount_exact = (
                    float(current.get("amount_usd", -1.0))
                    <= float(local.get("amount_usd", -2.0)) + 1e-6
                )
            else:
                amount_exact = math.isclose(
                    float(current.get("amount_usd", -1.0)), float(local.get("amount_usd", -2.0)),
                    rel_tol=0.0, abs_tol=1e-6,
                )
            if (
                any(current.get(field) != local.get(field) for field in ("role", "sku", "vcpus"))
                or str(current.get("sku_family", "")).lower() != str(local.get("sku_family", "")).lower()
                or not amount_exact
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


def reported_forecast(admitted, actual, forecast):
    """Report the seam-substituted forecast when admission relied on it.

    capacity_admission substitutes the readable actual for an unreadable
    forecast only under the operator's commissioning confirmation; a
    successful admission with no readable forecast can only mean that
    substitution ran, so callers see the exact admitted evidence instead
    of a None that reads as omitted.
    """
    if (
        admitted
        and forecast is None
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
    ):
        return float(actual)
    return forecast


def capacity_admission(
    env, state, inventory, candidate, provisional=(), ignore_reservation_id=None
):
    metrics = inventory["metrics"]
    actual = metrics.get("actual_usd")
    forecast = metrics.get("forecast_usd")
    if (
        forecast is None
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
        and env["policy_phase"] == "commissioning"
        and os.environ.get("FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST") == "1"
    ):
        # Bootstrap-only seam: a fresh resource group cannot train the
        # forecast model until real spend exists, and concurrent shard
        # admissions can exhaust the throttle window before the endpoint
        # even returns its untrained refusal. With the operator's explicit
        # commissioning confirmation, the readable actual substitutes for
        # any unreadable forecast; an unreadable actual still refuses.
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
    if action_type in ACTION_TYPES and worker is None:
        raise LifecycleError("a provider mutation cannot be minted without its exact worker")
    action = {
        "type": action_type,
        "deployment_generation": env["deployment_generation"],
        "owner": env["owner"],
    }
    if worker is not None:
        action.update({
            "slot": worker["slot"],
            "role": worker.get("role", "author"),
            "sku": worker["sku"],
            "sku_family": worker["sku_family"],
            "cloud_generation": worker["cloud_generation"],
            "bindings": worker["bindings"],
            "resources": worker.get("resources", {}),
            "cloud_instance_id": worker.get("cloud_instance_id"),
            "reservation_usd": worker.get("reservation_usd"),
        })
        if worker.get("retired_execute_key") is not None:
            action["retired_execute_key"] = worker["retired_execute_key"]
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
    record = {
        "slot": slot,
        "placement": "azure",
        "role": item.get("role", "author"),
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
    if item.get("task_home") is not None:
        # Additive, and ONLY for a compartment child: an ordinary worker record
        # keeps its exact bytes. ordinary_authority_attempt sees the worker and
        # not the queue item, so the release lane can only find the child's own
        # metadata if the path travels here.
        record["task_home"] = item["task_home"]
    return record


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


# One provider mutation touches exactly one slot's compartment, and this is
# the whole of it. Enumerated from every assignment, `pop` and `setdefault` in
# `apply_action_result`: the worker record itself (which `reset` removes), the
# one queue entry that worker owns 1:1, the execution record keyed by the
# action's request digest, and the fleet's completed-seconds accumulator.
APPLY_SCOPE = ("workers", "queue", "executions", "completed_worker_seconds")

# Coarse on purpose: it is per container, not per action type, so it permits
# writes no individual type makes (an `executions` entry from a `create`, say).
# A per-type contract would be tighter and would also have to change every time
# a type does, which is how an allowlist becomes a wedge on the money path.

# Not part of the apply's business, and not comparable either. `make_action`
# aliases live state into the action it mints (`action["request"]` IS the queue
# entry), and `copy.deepcopy` preserves that sharing, so applying into the copy
# also changes the copy's own record of the pending action while the original's
# stays put. Excluding the key is what makes the comparison meaningful; copying
# BOTH sides does not, because the apply writes only into the copy.
#
# It excludes the whole subtree rather than the aliased part, so an apply that
# rebound the pending claim state outright would go unseen. That is safe only
# because both call sites set it themselves immediately afterwards. The stored
# claims in pending_actions are deep copies and share nothing with the live
# document, but the exclusion also covers the caller popping its own slot's
# claim between apply and commit.
CALLER_OWNED_KEYS = ("pending_action", "pending_actions", "revision")


def assert_scoped(before, after, *, slot, queue_key, request_digest):
    """Refuse an apply whose effects reach outside one slot's compartment.

    The allowlist is the contract that lets two mutations for different slots
    be in flight at once. Checking it here rather than trusting a future edit
    is what keeps that true: a new assignment in `apply_action_result` that
    reaches another slot, or the queue, or capacity, fails on its first run
    instead of quietly corrupting a fleet whose other members are mid-flight.
    """

    for key in set(before) | set(after):
        if key in APPLY_SCOPE or key in CALLER_OWNED_KEYS:
            continue
        if before.get(key) != after.get(key):
            raise LifecycleError(
                "provider mutation result touched {} outside its slot; the pending "
                "action stays durable and will replay until this is resolved".format(key)
            )
    for container, allowed in (
        ("workers", {slot}),
        ("queue", {queue_key} if queue_key is not None else set()),
        ("executions", {request_digest} if request_digest is not None else set()),
    ):
        first = before.get(container) or {}
        second = after.get(container) or {}
        for key in set(first) | set(second):
            if key in allowed:
                continue
            if first.get(key) != second.get(key):
                raise LifecycleError(
                    "provider mutation result changed {}[{}], which its slot does "
                    "not own; the pending action stays durable and will replay "
                    "until this is resolved".format(container, key)
                )


def apply_result_transactionally(env, state, action, result):
    """Apply into a copy, prove the diff, then commit it in place.

    A raise from `apply_action_result` used to leave the passed state object
    partly mutated: `adopt_cloud_resources` writes the worker's resources
    before the queue owner is looked up, so a create whose queue entry
    disappeared left the adopted resource identities behind. That image was
    never saved on the raising path, but nothing structural stopped it from
    being saved by a later handler, and a partly-applied worker is precisely
    the record a `reset` would then act on for a VM that still exists.

    Applying into a copy makes that image unreachable rather than unlikely,
    and the caller's dict identity is preserved because callers hold it.
    """

    before = state
    working = copy.deepcopy(state)
    slot = str(action.get("slot", ""))
    # Read before the apply: `reset` removes the worker record, so its queue
    # owner is not derivable afterwards.
    worker = before.get("workers", {}).get(slot) or {}
    queue_key = worker.get("queue_key")
    apply_action_result(env, working, action, result)
    assert_scoped(
        before,
        working,
        slot=slot,
        queue_key=queue_key,
        request_digest=action.get("request_digest"),
    )
    state.clear()
    state.update(working)


def claim_pending(env, state, action):
    """Durably claim one slot's provider mutation. Caller holds the fleet lock
    AND the slot's lease; the claim's save must land before the provider is
    called, or a crash there strands a cloud mutation with no replay owner."""
    slot = str(action.get("slot", ""))
    if not slot.isdigit():
        raise LifecycleError("provider mutation carries no exact slot")
    existing = state["pending_actions"].get(slot)
    if existing is not None and existing.get("idempotency_key") != action["idempotency_key"]:
        # Overwriting a live claim silently discards its replay obligation:
        # the first execution never lands in executions, its dedupe
        # short-circuit never fires, and the guest command runs twice.
        raise LifecycleError(
            "slot {} still has an unapplied {} action; reconcile it first".format(
                slot, existing.get("type", "provider")))
    # deepcopy is load-bearing, not hygiene: make_action aliases live state
    # into the action (action["request"] IS the queue entry; bindings and
    # resources are the worker's own dicts), and apply_action_result mutates
    # some of those in place. A stored claim that can change after it was
    # hashed turns verify_state's self-hash check into a random wedge.
    state["pending_actions"][slot] = copy.deepcopy(action)
    save_state(env, state)


def apply_pending(env, action, result):
    """Apply one mutation's result. Caller holds the fleet lock AND the lease.

    The state is ALWAYS re-loaded here, never the caller's pre-call object:
    the provider ran outside the fleet lock, and anything read before it may
    already be stale.
    """
    state = load_state(env)
    slot = str(action["slot"])
    claimed = state["pending_actions"].get(slot)
    if not isinstance(claimed, dict) or claimed.get("idempotency_key") != action["idempotency_key"]:
        raise LifecycleError("durable claim for slot {} is no longer this action".format(slot))
    worker = state.get("workers", {}).get(slot) or {}
    queue_key = worker.get("queue_key")
    apply_result_transactionally(env, state, action, result)
    if action.get("type") == "reset" and queue_key is not None:
        # Provider reset already proved cloud-side absence.  Retire only this
        # queue owner's host snapshot before making completion durable.  A
        # crash after unlink but before save is an idempotent missing-path
        # retry; no same-profile peer path is ever inventoried.
        cleanup_placement_projection(env, state["queue"].get(queue_key) or {})
    state["pending_actions"].pop(slot, None)
    save_state(env, state)
    return state


def drain_pending(env, slot=None, strict=True):
    """Replay unapplied claims. Returns (drained_slots, refusals).

    A claim whose owning process is still ALIVE is skipped, never replayed:
    re-sending a key that is still in flight is the one thing the single
    fleet lock used to make impossible, and the only new way this design
    could create two cloud assignments for one key. Must not be called under
    the fleet lock (controller_lock refuses re-entry).
    """
    with controller_lock(env):
        snapshot = sorted(
            (load_state(env).get("pending_actions") or {}).items(), key=lambda p: int(p[0]))
    drained = []
    refusals = []
    for slot_key, action in snapshot:
        if slot is not None and slot_key != str(slot):
            continue
        try:
            with slot_lease(env, slot_key) as lease:
                # The snapshot may be stale: another process can have applied
                # this claim between the snapshot and this lease. Re-read
                # before re-sending, or an already-applied key is mutated a
                # second time for nothing and its absence then reads as a
                # refusal.
                with controller_lock(env):
                    current = load_state(env).get("pending_actions", {}).get(slot_key)
                if not isinstance(current, dict) or current.get("idempotency_key") != action.get("idempotency_key"):
                    continue
                result = provider_mutate(env, action, lease)
                with controller_lock(env):
                    apply_pending(env, action, result)
            drained.append(slot_key)
        except SlotBusy:
            continue
        except LifecycleError as exc:
            if strict:
                raise
            with controller_lock(env):
                clean = load_state(env)
                record_refusal(clean, clean["workers"].get(slot_key), exc)
                save_state(env, clean)
            refusals.append({"type": "replay-refused", "slot": int(slot_key), "reason": str(exc)[:500]})
    return drained, refusals


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
        if action.get("idle_release"):
            # Durable marker so status can LOUDLY list compute that was
            # idle-deallocated unattended and still awaits its proper
            # human-driven release.
            worker["idle_deallocated_at"] = worker.get("idle_deallocated_at") or iso_utc()
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
        if isinstance(execution, dict) and execution.get("schema") == EXECUTION_TERMINAL_SCHEMA:
            expected_task_command_id = (
                ((action.get("resources") or {}).get("task-command") or {}).get("id")
            )
            provisioning_state = str(execution.get("provisioning_state", "")).lower()
            execution_state = str(execution.get("execution_state", "")).lower()
            provisioning_terminal = provisioning_state in ("failed", "canceled")
            execution_terminal = (
                provisioning_state == "succeeded"
                and execution_state in ("failed", "canceled")
                and isinstance(execution.get("exit_code"), int)
                and not isinstance(execution.get("exit_code"), bool)
            )
            if (
                execution.get("request_digest") != action.get("request_digest")
                or execution.get("idempotency_key") != action.get("idempotency_key")
                or execution.get("disposition") != "provider-terminal"
                or not (provisioning_terminal or execution_terminal)
                or not isinstance(execution.get("task_command_id"), str)
                or not execution["task_command_id"]
            ):
                raise LifecycleError("provider terminal execution disposition is not exact")
            if execution["task_command_id"] != expected_task_command_id:
                raise ProviderResultIdentityRefused(
                    "provider terminal execution task-command identity differs from the claimed action"
                )
            terminal_state = execution_state if execution_terminal else provisioning_state
            raise LifecycleError(
                "provider-terminal {}: exact execution is {} and cannot be applied".format(
                    execution["request_digest"], terminal_state
                )
            )
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
        execution_request = action.get("request") or {}
        if execution_request.get("outcome_expected"):
            # A worker whose pinned supervisor predates the outcome contract
            # would run the command and answer with no outcome fields at all.
            # Refusing here turns that version skew into a visible failure
            # instead of a task whose commits silently never come home.
            if not isinstance(execution.get("outcome_present"), bool):
                raise LifecycleError(
                    "provider execution reports no outcome disposition for a landing task"
                )
        if execution_request.get("return_contract"):
            if execution.get("return_present") is not True:
                raise LifecycleError(
                    "provider execution reports no authorized return artifact bundle"
                )
            expected_return_ref = "refs/fm-return/{}".format(
                action["request_digest"][:32]
            )
            if execution.get("return_ref") != expected_return_ref:
                raise LifecycleError("provider execution return ref is not exact")
            for field in ("return_commit", "outcome_tip"):
                if not re.fullmatch(r"[0-9a-f]{40}", str(execution.get(field))):
                    raise LifecycleError(
                        "provider execution return {} is malformed".format(field)
                    )
            if not re.fullmatch(
                r"[0-9a-f]{64}", str(execution.get("return_manifest_sha256"))
            ):
                raise LifecycleError(
                    "provider execution return return_manifest_sha256 is malformed"
                )
            commits = execution.get("outcome_commits")
            if not isinstance(commits, int) or isinstance(commits, bool) or commits < 0:
                raise LifecycleError("provider execution outcome commit count is malformed")
            if execution.get("outcome_present") is not (commits > 0):
                raise LifecycleError(
                    "provider execution outcome presence differs from its commit count"
                )
            if not isinstance(execution.get("outcome_uncommitted_changes"), bool):
                raise LifecycleError(
                    "provider execution working-tree disposition is malformed"
                )
        if execution_request.get("service_return_contract"):
            present = execution.get("service_return_present")
            if not isinstance(present, bool):
                raise LifecycleError(
                    "provider execution reports no no-mistakes service return disposition")
            if present:
                if execution.get("return_present") is not True:
                    raise LifecycleError("no-mistakes service artifact has no return bundle")
                expected_return_ref = "refs/fm-return/{}".format(
                    action["request_digest"][:32])
                if execution.get("return_ref") != expected_return_ref:
                    raise LifecycleError("no-mistakes service return ref is not exact")
                for field in (
                    "return_commit", "outcome_tip", "return_manifest_sha256",
                    "step_outcome_sha256",
                ):
                    if not re.fullmatch(r"[0-9a-f]{40}" if field in (
                        "return_commit", "outcome_tip") else r"[0-9a-f]{64}",
                        str(execution.get(field)),
                    ):
                        raise LifecycleError(
                            "no-mistakes service return {} is malformed".format(field))
            elif execution.get("step_outcome_sha256") not in (None, ""):
                raise LifecycleError(
                    "absent no-mistakes service return asserted a step outcome digest")
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


def refresh_classifications(state, inventory, now=None):
    cloud = inventory_by_slot(inventory)
    claimed = state.get("pending_actions") or {}
    for worker in state["workers"].values():
        if str(worker["slot"]) in claimed:
            # An unapplied mutation owns this slot; a display value derived
            # from a record whose durable phase is not yet true would lie.
            continue
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
    # The first planning pass of a new UTC day snapshots the day's spend
    # baseline, whether or not any new compute is wanted; the caller's save
    # makes it durable.
    roll_daily_baseline(state, inventory["metrics"].get("actual_usd"), now)

    # Released work is the only path to ordinary destruction. With queued work,
    # reset immediately; otherwise deallocate first and honor the short cooldown.
    waiting = queued_items(state)
    claimed = state.get("pending_actions") or {}
    for slot_key in sorted(state["workers"], key=int):
        if slot_key in claimed:
            # An unapplied mutation owns this slot, so its durable record is
            # deliberately not yet the truth: delete-compute writes phase
            # before it can raise, and reset marks the queue complete before
            # parse_time can raise. The fleet-wide pre-drain used to make
            # planning on such a record unreachable; this skip replaces that
            # shield, and the post-convergence drain owns the replay.
            continue
        worker = state["workers"][slot_key]
        current = cloud.get(worker["slot"])
        classification, note = classify_worker(worker, current, now=now)
        worker["last_classification"] = classification
        worker["classification_note"] = note
        if not worker.get("release_proof"):
            # C3 idle release: an assigned worker whose recorded task ended
            # long ago gets its compute DEALLOCATED unattended - reversible,
            # stops the spend - never released or reset: releasing requires
            # authority receipts a machine cannot mint, and destruction stays
            # behind the ordinary human-driven release proof.
            if classification == "assigned" and idle_deallocate_due(env, state, worker, current, now):
                return make_action(env, "deallocate", worker=worker, idle_release=True)
            continue
        if classification == "retained-for-investigation":
            continue
        if classification == "assigned":
            return make_action(env, "deallocate", worker=worker)
        if classification == "deallocated":
            if not worker.get("cooldown_started_at"):
                # Only the controller's own deallocate apply stamps this field,
                # but surrender's dark-compute gate REQUIRES an operator-side
                # deallocate, which never stamps it. Left null, this branch
                # used to compute started=now on every pass, so the cooldown
                # clock restarted forever and delete-compute never became due
                # (live: slot 1, d2-probe-20260819). Stamp durably under the
                # caller's lock hold so the clock starts at first observation.
                worker["cooldown_started_at"] = iso_utc(now)
            started = parse_time(worker["cooldown_started_at"])
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
    bound_refusal, override_day = daily_bound_refusal(
        env, state, inventory["metrics"].get("actual_usd"), now=now
    )
    if bound_refusal is not None:
        return {"type": "admission-refused", "reason": bound_refusal, "slot": slot, "reservation_usd": 0.0}
    admitted, reason, reservation = admission_result(env, state, inventory, slot, item)
    if not admitted:
        return {"type": "admission-refused", "reason": reason, "slot": slot, "reservation_usd": reservation}
    if override_day is not None:
        # Recorded only now that admission actually admitted: the override
        # carried this create past the bound, so its use is an effect, not an
        # intent.
        record_daily_override_use(
            env, state, inventory["metrics"].get("actual_usd"), override_day, now=now
        )
    worker = create_worker_record(env, state, slot, item, reservation)
    state["workers"][str(slot)] = worker
    item["status"] = "assigning"
    shared_admission_digest = digest_value({
        "slot": worker["slot"], "sku": worker["sku"], "sku_family": worker["sku_family"],
        "assignment_generation": worker["assignment_generation"],
        "reservation_usd": reservation,
    })
    extra = {}
    if override_day is not None:
        # The operator override is never silent: the create action itself
        # carries the day it was admitted past the bound for, and the durable
        # daily_bound_override_used record plus status output repeat it.
        extra["daily_bound_override"] = override_day
    action = make_action(
        env, "create", worker=worker, item=item, reuse_retained=False,
        shared_admission_digest=shared_admission_digest, **extra,
    )
    return action


def reconcile(env, apply, confirm_subscription):
    """One bounded convergence pass. Provider calls run OUTSIDE the fleet lock;
    each iteration is (short hold: plan+claim) -> (no hold: mutate) ->
    (short hold: re-read+apply). The drain of previously stranded claims runs
    AFTER convergence, in command_reconcile: planning past a claimed slot is
    safe (the planner skips it), so a wedged or hours-long replay can no
    longer stop the fleet from converging, and the convergence work is
    already durable when a drain blocks."""
    if apply and confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    actions = []
    inventory = None
    for _ in range(64):
        inventory = provider_call(env, "inventory")["inventory"]
        with contextlib.ExitStack() as stack:
            action = None
            with controller_lock(env):
                state = load_state(env)
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
                    # Dry planning may have allocated an in-memory worker
                    # record. Do not persist or continue beyond the first
                    # mutation boundary.
                    if action["type"] == "create":
                        state["workers"].pop(str(action.get("slot")), None)
                        key = request_key(action["request"]["task"], action["request"]["task_generation"])
                        state["queue"][key]["status"] = "queued"
                    return actions, inventory
                lease = stack.enter_context(slot_lease(env, action["slot"]))
                claim_pending(env, state, action)
            try:
                result = provider_mutate(env, action, lease)
                with controller_lock(env):
                    apply_pending(env, action, result)
            except LifecycleError as exc:
                # NEVER the half-applied object: the refusal is recorded on a
                # clean load, and the durable claim stays for the drain.
                with controller_lock(env):
                    clean = load_state(env)
                    record_refusal(clean, clean["workers"].get(str(action.get("slot"))), exc)
                    save_state(env, clean)
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


def compartment_projection(state):
    """Bounded status of every live secondmate compartment, from controller.json
    fields ONLY: role/slot/status from the queue entry, children_total and the
    assignment timestamps from the worker record, and the active-children count
    from the same queue scan the child bounds use. Leg progress and the exact
    TTL clock are the compartment monitor's local state and are deliberately
    NOT invented here; ttl_anchor is the durable assignment anchor (assigned_at,
    else created_at), the controller's honest approximation of when compartment
    compute began. session_legs is projected only when a worker record actually
    carries it (additive, per design B.2)."""
    compartments = []
    for key, item in sorted(state["queue"].items()):
        if item.get("role") != "secondmate" or item.get("status") == "complete":
            continue
        worker = None
        slot = item.get("slot")
        if slot is not None:
            candidate = state["workers"].get(str(slot))
            if candidate is not None and candidate.get("queue_key") == key:
                worker = candidate
        children_active = sum(
            1 for entry in state["queue"].values()
            if entry.get("parent_task") == item.get("task")
            and entry.get("parent_task_generation") == item.get("task_generation")
            and entry.get("status") != "complete"
        )
        entry = {
            "task": item.get("task"),
            "task_generation": item.get("task_generation"),
            "status": item.get("status"),
            "slot": int(slot) if slot is not None else None,
            "assignment_generation": (worker or {}).get("assignment_generation"),
            "children_active": children_active,
            "children_total": int((worker or {}).get("children_total", 0) or 0),
            "ttl_anchor": (worker or {}).get("assigned_at") or (worker or {}).get("created_at"),
        }
        if worker is not None and "session_legs" in worker:
            entry["session_legs"] = worker["session_legs"]
        compartments.append(entry)
    return compartments


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
    # Read-only daily-bound evidence: the projection never rolls the durable
    # baseline (status without --live may run outside a saving path), so a
    # baseline from an earlier day reports None spend until a reconcile or a
    # live status rolls it.
    baseline = state.get("daily_cost_baseline")
    actual = metrics.get("actual_usd")
    today = utc_day()
    daily_spend = None
    if (
        isinstance(baseline, dict)
        and baseline.get("utc_day") == today
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
    ):
        daily_spend = round(max(0.0, float(actual) - float(baseline["actual_usd_at_day_start"])), 6)
    idle_deallocated = [
        {
            "slot": int(worker["slot"]),
            "task": worker.get("bindings", {}).get("task"),
            "task_generation": worker.get("bindings", {}).get("task_generation"),
            "assignment_generation": worker["assignment_generation"],
            "idle_deallocated_at": worker.get("idle_deallocated_at"),
        }
        for worker in state["workers"].values()
        if worker.get("idle_deallocated_at") and not worker.get("released_at")
    ]
    selected_loads = leased_placement_accounts(state)
    profile_loads = {}
    for (_, profile, binding), load in selected_loads.items():
        aggregate = profile_loads.setdefault(
            (profile, binding), {"active": 0, "tasks": []})
        aggregate["active"] += load["active"]
        aggregate["tasks"].extend(load["tasks"])
    account_placements = []
    for item in state["queue"].values():
        if item.get("status") == "complete" or not item.get("account_profile"):
            continue
        load_key = (item.get("account_profile"), item.get("account_binding"))
        account_placements.append({
            "task": item.get("task"),
            "task_generation": item.get("task_generation"),
            "status": item.get("status"),
            "account_profile": item.get("account_profile"),
            "account_binding": item.get("account_binding"),
            "account_home": item.get("account_home"),
            "account_projection_binding": item.get("account_projection_binding"),
            "assignment_generation": (
                state["workers"].get(str(item.get("slot")), {}).get("assignment_generation")
                if item.get("slot") is not None else None
            ),
            "profile_active_load": profile_loads.get(load_key, {}).get("active", 0),
        })
    account_placements.sort(key=lambda entry: (
        entry["account_profile"], entry.get("account_binding") or "",
        entry["task"] or "",
    ))
    account_profile_loads = [
        {
            "account_profile": profile,
            "account_binding": binding,
            "active_placements": load["active"],
        }
        for (profile, binding), load in sorted(
            profile_loads.items(), key=lambda pair: (pair[0][0], pair[0][1])
        )
    ]
    return {
        "schema": "fm.worker-status/v1",
        "daily_bound_usd": env["daily_bound_usd"],
        "daily_bound_day": today,
        "daily_cost_baseline": baseline,
        "daily_recorded_spend_usd": daily_spend,
        "daily_bound_tripped": daily_spend is not None and daily_spend >= env["daily_bound_usd"],
        "daily_bound_override": env["daily_bound_override"],
        "daily_bound_override_used": state.get("daily_bound_override_used"),
        "idle_release_seconds": env["idle_release_seconds"],
        "idle_deallocated_workers": sorted(idle_deallocated, key=lambda entry: entry["slot"]),
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
        "compartments": compartment_projection(state),
        # Every placement remains visible even when several use one upstream
        # identity.  The reusable digest and per-profile active load expose
        # provider-quota pressure without raw account identity or token bytes.
        "account_placements": account_placements,
        "account_profile_loads": account_profile_loads,
        "idle_cooldown_seconds": env["cooldown_seconds"],
        "warm_idle_target": env["warm_idle"],
        "retained_disks": retained_disks,
        "cleanup_refusals": state["cleanup_refusals"][-10:],
        "pending_mutations": [
            {"slot": int(slot), "type": action.get("type"),
             "lease_held": slot_lease_held(env, slot)}
            for slot, action in sorted(
                (state.get("pending_actions") or {}).items(), key=lambda p: int(p[0]))
        ],
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
    for compartment in status.get("compartments") or []:
        line = (
            "compartment: task={}@{} status={} slot={} children={}/{} ttl-anchor={}".format(
                compartment["task"], compartment["task_generation"], compartment["status"],
                compartment["slot"], compartment["children_active"],
                compartment["children_total"], compartment["ttl_anchor"],
            ))
        if "session_legs" in compartment:
            line += " legs={}".format(compartment["session_legs"])
        print(line)
    for load in status.get("account_profile_loads") or []:
        print("account-profile-load: profile={} active={} account-binding={}".format(
            load["account_profile"], load["active_placements"],
            load["account_binding"],
        ))
    for placement in status.get("account_placements") or []:
        print(
            "account-placement: profile={} load={} task={}@{} status={} "
            "account-binding={} projection={} home={}".format(
                placement["account_profile"], placement["profile_active_load"],
                placement["task"], placement["task_generation"],
                placement["status"], placement["account_binding"],
                placement.get("account_projection_binding") or "legacy",
                placement["account_home"],
            )
        )
    if status["pending_mutations"]:
        print("pending-mutations: {}".format(json.dumps(
            status["pending_mutations"], sort_keys=True, separators=(",", ":"))))
    print("daily-bound: day={} recorded-day-spend={} bound={} tripped={} override={}".format(
        status["daily_bound_day"], status["daily_recorded_spend_usd"],
        status["daily_bound_usd"], str(status["daily_bound_tripped"]).lower(),
        status["daily_bound_override"] or "none",
    ))
    if status["daily_bound_override_used"]:
        print("DAILY BOUND OVERRIDE USED: {}".format(json.dumps(
            status["daily_bound_override_used"], sort_keys=True, separators=(",", ":"))))
    for entry in status["idle_deallocated_workers"]:
        print(
            "IDLE-DEALLOCATED WORKER: slot={} task={}@{} generation={} dark since {} - "
            "compute spend stopped unattended; RELEASE IT PROPERLY "
            "(authority-receipt then release, or surrender)".format(
                entry["slot"], entry["task"], entry["task_generation"],
                entry["assignment_generation"], entry["idle_deallocated_at"],
            ))
    print("idle: cooldown={}s warm={} idle-release={}s retained-disks={} cleanup-refusals={}".format(
        status["idle_cooldown_seconds"], status["warm_idle_target"],
        status["idle_release_seconds"],
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
    request.add_argument(
        "--role", choices=("author", "secondmate", "no-mistakes"), default="author")
    request.add_argument("--parent-task", default=None)
    request.add_argument("--parent-task-generation", default=None)
    request.add_argument(
        "--task-home", default=None,
        help="the compartment child's own home, where its task metadata authorities live; "
             "the money document stays under FM_HOME")
    request.add_argument("--eligible", action="store_true")
    request.add_argument("--required", action="store_true", help="mark non-discretionary recovery/landing work")

    withdraw_parser = sub.add_parser(
        "withdraw", help="retire one exact projecting/queued request no worker ever took")
    withdraw_parser.add_argument("--task", required=True)
    withdraw_parser.add_argument("--task-generation", required=True)
    withdraw_parser.add_argument("--confirm-withdraw", action="store_true")
    withdraw_parser.add_argument("--confirm-subscription", required=True)
    withdraw_parser.add_argument(
        "--task-home-out", default=None,
        help="write the authorized task home for this removal to this file; the\n             wrapper reads it to remove the task's cloud state from the home it\n             was staged in rather than from the controller's own")

    surrender_parser = sub.add_parser(
        "surrender",
        help="release one exact assigned worker whose ordinary release authority is unrecoverable",
    )
    surrender_parser.add_argument("--task", required=True)
    surrender_parser.add_argument("--task-generation", required=True)
    surrender_parser.add_argument("--reason", required=True)
    surrender_parser.add_argument("--output", required=True)
    surrender_parser.add_argument("--confirm-surrender", action="store_true")
    surrender_parser.add_argument(
        "--task-home-out", default=None,
        help="write the authorized task home for this removal to this file; the\n             wrapper reads it to remove the task's cloud state from the home it\n             was staged in rather than from the controller's own")
    surrender_parser.add_argument(
        "--confirm-discard-unlanded", action="store_true",
        help="acknowledge that recorded execute outcomes never proven landed are discarded",
    )
    surrender_parser.add_argument(
        "--confirm-orphan-children", action="store_true",
        help="acknowledge that live compartment children are durably reparented to the primary",
    )
    surrender_parser.add_argument("--confirm-subscription", required=True)
    abandon_parser = sub.add_parser(
        "abandon-claim",
        help="retire one slot's unapplied claim by replaying its mutation to completion first",
    )
    abandon_parser.add_argument("--slot", required=True)
    abandon_parser.add_argument("--idempotency-key", required=True)
    abandon_parser.add_argument("--confirm-abandon", action="store_true")
    abandon_parser.add_argument("--confirm-subscription", required=True)

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

    capacity_retire = sub.add_parser(
        "capacity-retire-fence",
        help="permanently close one exact specialized capacity fence after release",
    )
    capacity_retire.add_argument("--fence-binding", required=True)
    capacity_retire.add_argument("--reservation-id", action="append", required=True)
    capacity_retire.add_argument("--retirement-receipt", required=True)
    capacity_retire.add_argument("--confirm-subscription", required=True)

    execute = sub.add_parser("execute", help="run one exact private task command and collect its bound result")
    execute.add_argument("--task", required=True)
    execute.add_argument("--task-generation", required=True)
    execute.add_argument("--assignment-generation", required=True)
    execute.add_argument("--wall-seconds", type=int, default=3600)
    execute.add_argument("--payload-dir", default=None)
    execute.add_argument("--account-dir", default=None)
    execute.add_argument("--outcome-dir", default=None)
    execute.add_argument("--return-kind", choices=("ship", "scout"), default=None)
    execute.add_argument(
        "--existing-task-disk", action="store_true",
        help="continue or collect an assigned task disk without replacing its repository",
    )
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

    service_complete = sub.add_parser(
        "service-complete",
        help="release one no-mistakes service worker after its exact execution is recorded",
    )
    service_complete.add_argument("--task", required=True)
    service_complete.add_argument("--task-generation", required=True)
    service_complete.add_argument("--assignment-generation", required=True)
    service_complete.add_argument("--request-digest", required=True)
    service_complete.add_argument("--confirm-subscription", required=True)

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

    message_put = sub.add_parser(
        "message-put",
        help="deliver one bounded content-addressed message blob to the compartment session inbox",
    )
    message_put.add_argument("--task", required=True)
    message_put.add_argument("--task-generation", required=True)
    message_put.add_argument("--assignment-generation", required=True)
    message_put.add_argument("--file", default=None, help="bounded JSON message payload")
    message_put.add_argument("--attach", default=None, help="bounded binary attachment (child delta bundle)")

    message_collect = sub.add_parser(
        "message-collect",
        help="fetch new compartment session outbox blobs without verification or overwrite",
    )
    message_collect.add_argument("--task", required=True)
    message_collect.add_argument("--task-generation", required=True)
    message_collect.add_argument("--assignment-generation", required=True)
    message_collect.add_argument("--output-dir", required=True)
    message_collect.add_argument(
        "--after", default=None,
        help="resume after this local outbox name (the cursor a previous summary reported)",
    )

    chain_tip = sub.add_parser(
        "compartment-chain-tip",
        help="record one compartment's verified outbox chain tip on its controller-owned worker record",
    )
    chain_tip.add_argument("--task", required=True)
    chain_tip.add_argument("--task-generation", required=True)
    chain_tip.add_argument("--assignment-generation", required=True)
    chain_tip.add_argument("--sequence", type=int, required=True)
    chain_tip.add_argument("--chain-digest", required=True)

    status = sub.add_parser("status", help="show bounded local lifecycle and cost evidence")
    status.add_argument("--live", action="store_true")
    status.add_argument("--json", action="store_true")

    sub.add_parser("acceptance-plan", help="print the isolated post-release acceptance checklist")
    return top


def authoritative_request_bindings(env, task, generation, task_home=None):
    require_id("task", task)
    require_id("task generation", generation)
    # FM_HOME does three separable jobs at once: (1) where the REQUESTING
    # task's local authorities live (this metadata read), (2) the identity
    # stamped into the request's home_binding, and (3) the identity of the
    # money document. Jobs 1 and 2 belong to the requester; job 3 belongs to
    # the controller. The secondmate compartment child is the first case where
    # they differ, so the origin of the local authorities is a PARAMETER while
    # FM_HOME stays put - because FM_HOME is what names the one document.
    # An authorized origin is proven by authorize_task_home under the lock;
    # nothing here decides authority.
    origin = task_home or env["home"]
    metadata = origin / "state" / (task + ".meta")
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
        "home_binding": home_binding(origin),
        # The POOL, not one snapshot.  The task metadata proves which canonical
        # host-owned source it may draw from; the controller selects the
        # least-loaded usable profile under its lock and mints a reusable
        # account binding plus an assignment-private projection in
        # `command_request`.
        "account_pool_home": str(account_home),
        "worktree_binding": digest_value({"worktree": str(worktree), "git_dir": str(git_dir)}),
        "repository_binding": hashlib.sha256(head.encode("ascii")).hexdigest(),
        "repository_generation": head,
    }


SECONDMATE_HOME_MARKER = ".fm-secondmate-home"
# The CANONICAL registry reader, not a second implementation of it. Every shell
# consumer resolves a secondmate home through
# bin/fm-account-routing-lib.sh's fm_secondmate_registry_query, which refuses
# the WHOLE registry on any malformed line and additionally requires an
# absolute home, no ".." component, an lstat on every path component with a
# symlink refusal, an existing directory, no duplicate ids and no duplicate
# homes by device:inode. A regex over the same line shape reproduces the shape
# and none of that, so a truncated or hand-annotated registry would make every
# shell consumer refuse wholesale while the money path kept authorizing from
# it. The money path must be the STRICTEST reader of that document, never the
# most permissive, so it calls the same reader.
SECONDMATE_REGISTRY_READER = ROOT / "bin" / "fm-account-routing-lib.sh"
SECONDMATE_REGISTRY_QUERY = (
    'set -u\n'
    '. "$1" || exit 1\n'
    'fm_secondmate_registry_query "$2" query "$3" home\n'
)


def registered_secondmate_home(env, secondmate):
    """The home the PRIMARY registered for this secondmate, or a refusal."""
    registry = env["home"] / "data" / "secondmates.md"
    try:
        result = subprocess.run(
            ["bash", "-c", SECONDMATE_REGISTRY_QUERY, "fm-secondmate-registry",
             str(SECONDMATE_REGISTRY_READER), str(registry), secondmate],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=PROVIDER_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise LifecycleError(
            "the primary's secondmate registry could not be read: {}".format(exc))
    if result.returncode != 0:
        # One refusal for every way the canonical reader says no: absent,
        # malformed anywhere, unsafe home path, duplicate id, duplicate home,
        # or not exactly one entry for this secondmate.
        raise LifecycleError(
            "the primary's secondmate registry does not validly register secondmate {}".format(
                secondmate))
    home = result.stdout.decode("utf-8", errors="replace").strip()
    if not home.startswith("/"):
        raise LifecycleError(
            "the primary's registered home for secondmate {} is not absolute".format(secondmate))
    return Path(home)


def _within(ancestor, path):
    return ancestor == path or ancestor in path.parents


def safe_marker_text(value):
    """A bounded, printable rendering of caller-controlled marker bytes."""
    printable = "".join(
        character if character.isprintable() and character != '"' else "?"
        for character in value
    )
    return (printable[:64] + "...") if len(printable) > 64 else printable


def authorize_task_home(env, parent, task_home, expected_home_binding=None):
    """Prove the primary authorized this task home for this parent compartment.

    Called INSIDE the controller lock, immediately before enforce_child_bounds,
    so the authoritative decision and the bounds it anchors are taken under one
    hold over one document. It is also called BEFORE the bindings are minted,
    because minting reads metadata, resolves caller-named paths and shells out
    to git under a directory nothing has authorized yet.

    Nothing here is self-authorizing. The chain has three independent links and
    every one of them is owned by the primary:
      1. the marker file inside the task home NAMES a secondmate id, and the
         directory satisfies the same home-shape rules validate_secondmate_home
         applies (not the active home, not nested either way with it, not the
         firstmate repo, and a real firstmate home carrying AGENTS.md and bin/);
      2. the PRIMARY's own data/secondmates.md, read through the CANONICAL
         reader, must map that id to exactly this resolved directory - an entry
         only the primary could have written;
      3. enforce_child_bounds (unchanged, next) then proves that id is an
         ASSIGNED role=secondmate entry in this controller's own document.
    A directory that plants its own marker fails link 2; a registry entry that
    names a home which does not carry the matching marker fails link 1; a
    registered, marked home whose secondmate is not a live compartment here
    fails link 3.
    """
    require_id("parent_task", parent)
    if not task_home.is_absolute():
        raise LifecycleError("task home must be an absolute path")
    # The home-shape rules validate_secondmate_home enforces, which a bare
    # marker check does not: the PRIMARY's own home carries no marker today,
    # but nothing structural stopped a task home from naming it.
    if _within(task_home, env["home"]) or _within(env["home"], task_home):
        raise LifecycleError(
            "task home cannot be, contain, or sit inside the active firstmate home")
    if _within(task_home, ROOT) or _within(ROOT, task_home):
        raise LifecycleError(
            "task home cannot be, contain, or sit inside the firstmate repository")
    marker = task_home / SECONDMATE_HOME_MARKER
    if marker.is_symlink() or not marker.is_file():
        raise LifecycleError(
            "task home {} carries no ordinary secondmate home marker".format(task_home))
    try:
        # Trailing newlines only, exactly what the shell readers' $(cat ...)
        # strips. Stripping leading whitespace would admit " smc-1" as smc-1.
        marked = marker.read_text(encoding="utf-8").rstrip("\n")
    except (OSError, UnicodeDecodeError) as exc:
        raise LifecycleError("task home secondmate home marker is unreadable: {}".format(exc))
    if marked != parent:
        raise LifecycleError(
            'task home {} is marked for secondmate "{}", not the parent compartment {}'.format(
                task_home, safe_marker_text(marked) or "unknown", parent))
    for required, label in ((task_home / "AGENTS.md", "AGENTS.md"), (task_home / "bin", "bin/")):
        if not required.exists():
            raise LifecycleError(
                "task home {} is not a firstmate home (missing {})".format(task_home, label))
    registered = registered_secondmate_home(env, parent)
    if registered.resolve() != task_home:
        raise LifecycleError(
            "task home {} is not the home the primary registered for secondmate {} ({})".format(
                task_home, parent, registered))
    if expected_home_binding is not None and expected_home_binding != home_binding(task_home):
        # Belt and braces for the gated asserted-bindings lane, where the
        # request's own home_binding does not come from this directory.
        raise LifecycleError(
            "task home does not match the request's own home binding")


def authority_home(env, record):
    """Where THIS task's ordinary local authorities live.

    FM_HOME names the money document; it does not name where a compartment
    child's state/<task>.meta lives. Without this the release lane would look
    for the child's metadata under the primary and find nothing, and an
    admitted child would hold a live worker slot with no ordinary exit - and
    worse, the resulting "WORKER AUTHORITY REFUSED" would read as a genuine
    refusal and qualify every compartment child for surrender from the moment
    it was assigned.
    """
    task_home = record.get("task_home")
    if task_home is None:
        return env["home"]
    if not isinstance(task_home, str) or not task_home.startswith("/"):
        raise LifecycleError("durable task home is malformed")
    resolved = Path(task_home).resolve()
    recorded = record.get("home_binding") or (record.get("bindings") or {}).get("home_binding")
    if home_binding(resolved) != recorded:
        raise LifecycleError("durable task home does not match its recorded home binding")
    return resolved


def enforce_child_bounds(env, state, item):
    """Every bound on secondmate child compute, under the ONE lock that inserts.

    A single document and a single exclusive hold is what makes these checks
    non-racy - the same atomicity ensure_unique_bindings already relies on.
    """
    parent_key = request_key(item["parent_task"], item["parent_task_generation"])
    parent = state["queue"].get(parent_key)
    if parent is None or parent.get("role") != "secondmate" or parent.get("status") != "assigned":
        raise LifecycleError(
            "child request parent {}@{} is not an assigned secondmate compartment".format(
                item["parent_task"], item["parent_task_generation"]))
    active = sum(
        1 for entry in state["queue"].values()
        if entry.get("parent_task") == item["parent_task"]
        and entry.get("parent_task_generation") == item["parent_task_generation"]
        and entry.get("status") != "complete"
    )
    if active >= env["secondmate_child_max"]:
        raise LifecycleError(
            "secondmate {} already owns {} active children (cap {})".format(
                item["parent_task"], active, env["secondmate_child_max"]))
    parent_worker = state["workers"].get(str(parent.get("slot")))
    if parent_worker is None or parent_worker.get("queue_key") != parent_key:
        # Unreachable through code paths today (assigned implies a worker,
        # reset both pops the worker and completes the item), so reaching it
        # means hand-edited or corrupted state; the lifetime bound must not
        # degrade silently there.
        raise LifecycleError(
            "assigned secondmate compartment {} has no exact worker record".format(
                item["parent_task"]))
    lifetime = int(parent_worker.get("children_total", 0))
    if lifetime >= env["secondmate_child_total"]:
        raise LifecycleError(
            "secondmate {} reached its lifetime child total ({}, cap {})".format(
                item["parent_task"], lifetime, env["secondmate_child_total"]))


def command_request(env, args):
    # --task-home is the compartment child's ONE new capability: it moves
    # where the requesting task's local authorities are read from (and the
    # identity stamped into home_binding), never where the money document
    # lives. It is refused outside the exact shape that marks a compartment
    # child, so no other lane can reach a foreign home.
    task_home = None
    if getattr(args, "task_home", None) is not None:
        if (
            args.parent_task is None
            or args.parent_task_generation is None
            or args.role != "author"
            or args.owner_kind != "secondmate"
        ):
            raise LifecycleError("task home is owned by compartment child requests only")
        if not args.task_home.startswith("/"):
            # A relative path would resolve against the REQUEST PROCESS'S cwd,
            # which would make the caller's working directory, not the
            # registry, the anchor for what gets authorized.
            raise LifecycleError("--task-home must be an absolute path")
        task_home = Path(args.task_home).resolve()
        # Authorize BEFORE minting: the mint reads <task_home>/state/<task>.meta,
        # resolves and stats caller-named worktree and account paths, and runs
        # git under them. None of that may happen under a directory the primary
        # has not authorized. The authoritative decision is still taken again
        # under the lock, below.
        authorize_task_home(env, args.parent_task, task_home)
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
        bindings = authoritative_request_bindings(
            env, args.task, args.task_generation, task_home=task_home)
    # DURABLE on the item, not consumed here: the queue entry records which
    # canonical provider-account pool its immutable snapshot came from, so an
    # audit never has to re-read task metadata teardown may already have removed.
    pool_home = bindings.get("account_pool_home")
    item = {
        "schema": REQUEST_SCHEMA,
        "task": args.task,
        "task_generation": args.task_generation,
        **bindings,
        "owner_kind": args.owner_kind,
        "role": args.role,
        "eligible": args.eligible,
        "discretionary": not args.required,
        "status": "queued",
        "enqueued_at": iso_utc(),
    }
    if args.parent_task is not None or args.parent_task_generation is not None:
        item["parent_task"] = args.parent_task
        item["parent_task_generation"] = args.parent_task_generation
    if task_home is not None:
        # DURABLE, because the release lane needs the PATH and not only the
        # digest: authority_home reads it back to tell fm-worker-authority.py
        # where this task's own state/<task>.meta lives.
        item["task_home"] = str(task_home)
    if pool_home is None:
        # The asserted-bindings lane already carries an account_binding of its
        # own, so there is nothing to select; it is reachable only with the
        # test env var AND a fixture provider (checked above).
        verify_request(item)
    key = request_key(item["task"], item["task_generation"])
    with controller_lock(env):
        state = load_state(env)
        existing = state["queue"].get(key)
        if existing is not None:
            # Replay reuses the SAME profile and assignment-private snapshot,
            # because selection runs only on the branch that creates this
            # entry.  A replay cannot consume another load-balanced placement.
            identity_fields = (
                "schema", "task", "task_generation", "home_binding",
                "worktree_binding", "repository_binding", "repository_generation",
                "owner_kind", "role", "eligible", "discretionary",
                "parent_task", "parent_task_generation", "task_home",
                "account_pool_home",
            )
            if pool_home is None:
                identity_fields += ("account_binding",)
            if any(existing.get(field) != item.get(field) for field in identity_fields):
                raise LifecycleError("task generation already exists with different queue identity")
            if existing.get("status") == "projecting":
                # A crash may interrupt the snapshot write, but never before
                # the queue owns its exact path.  The same request resumes from
                # that state, retaining profile, upstream binding, and private
                # projection identity.
                write_placement_snapshot(env, existing)
                existing["status"] = "queued"
                existing["projected_at"] = iso_utc()
                save_state(env, state)
            if existing.get("account_home"):
                # The profile name is reported separately because the home is
                # keyed on an assignment-private projection binding, not on the
                # reusable local label or upstream account digest.
                print("account-profile {}".format(existing.get("account_profile") or ""))
                print("account-home {}".format(existing["account_home"]))
            print("request already exists with exact identity")
            return
        if pool_home is not None:
            # Selection is one act under one lock over one document.  The
            # durable `projecting` state is saved before credential bytes are
            # written, so a crash leaves a resumable owner rather than an
            # orphan snapshot.
            item.update(select_placement_account(env, state, pool_home, item))
        verify_request(item)
        ensure_unique_bindings(state, item)
        if item.get("parent_task") is not None:
            if task_home is not None:
                authorize_task_home(
                    env, item["parent_task"], task_home,
                    expected_home_binding=item["home_binding"])
            enforce_child_bounds(env, state, item)
        if item.get("role") == "secondmate":
            active_compartments = sum(
                1 for entry in state["queue"].values()
                if entry.get("role") == "secondmate"
                and entry.get("status") != "complete"
            )
            if active_compartments >= env["secondmate_max"]:
                raise LifecycleError(
                    "secondmate compartment cap reached ({} active, cap {})".format(
                        active_compartments, env["secondmate_max"]))
        if pool_home is not None:
            item["status"] = "projecting"
        state["queue"][key] = item
        if item.get("parent_task") is not None:
            parent_key = request_key(item["parent_task"], item["parent_task_generation"])
            parent_worker = state["workers"][str(state["queue"][parent_key].get("slot"))]
            parent_worker["children_total"] = int(parent_worker.get("children_total", 0)) + 1
        save_state(env, state)
        if pool_home is not None:
            write_placement_snapshot(env, item)
            item["status"] = "queued"
            item["projected_at"] = iso_utc()
            save_state(env, state)
    if item.get("account_home"):
        # The caller stages the provider credential from this request's
        # assignment-private snapshot.  Printed as a path and slot name, never
        # as contents; another placement using the same profile has another
        # path and cleanup authority.
        print("account-profile {}".format(item.get("account_profile") or ""))
        print("account-home {}".format(item["account_home"]))
    print("queued {} generation {} for one isolated author worker".format(item["task"], item["task_generation"]))


def public_action(action):
    value = {
        key: action[key]
        for key in (
            "type", "slot", "sku", "sku_family", "reason", "reservation_usd",
            "idle_release", "daily_bound_override",
        )
        if key in action
    }
    if isinstance(action.get("bindings"), dict):
        value["assignment_generation"] = action["bindings"]["assignment_generation"]
    return value


def command_reconcile(env, args):
    actions, inventory = reconcile(env, args.apply, args.confirm_subscription)
    if args.apply:
        drained, refusals = drain_pending(env, strict=False)
        actions.extend(refusals)
    with controller_lock(env):
        state = load_state(env)
        status = status_projection(env, state, inventory)
    safe_actions = [public_action(action) for action in actions]
    output = {"actions": safe_actions, "status": status}
    if args.json:
        print(json.dumps(output, sort_keys=True, separators=(",", ":")))
    else:
        for action in safe_actions:
            if action["type"] == "admission-refused":
                print("admission refused: {}".format(action["reason"]))
            elif action["type"] == "replay-refused":
                print("replay refused: slot={} {}".format(action.get("slot"), action["reason"]))
            else:
                print("{}: slot={} generation={}".format(
                    action["type"], action.get("slot"),
                    (action.get("bindings") or {}).get("assignment_generation", "n/a"),
                ))
                if action.get("daily_bound_override"):
                    print("DAILY BOUND OVERRIDE: {} on slot {} admitted past the daily bound "
                          "for day {} by FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE".format(
                              action["type"], action.get("slot"), action["daily_bound_override"]))
                if action.get("idle_release"):
                    print("IDLE DEALLOCATE: slot {} idled past {} seconds after its last "
                          "recorded execution; compute is dark, release it properly".format(
                              action.get("slot"), env["idle_release_seconds"]))
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


def refuse_retired_capacity_fence(state, fence):
    if fence in state["retired_capacity_fences"]:
        raise LifecycleError("retired capacity fence cannot admit another reservation")


def matching_capacity_reservation(state, candidate):
    reservation_id = candidate["reservation_id"]
    existing = state["capacity_reservations"].get(reservation_id)
    if existing is None:
        return None, None
    identity_fields = (
        "schema", "reservation_id", "fence_binding", "role", "workload_role", "sku",
        "sku_family", "vcpus", "discretionary",
    )
    # A shape constituent is reserved by its parent with a cushioned
    # worst-case amount; the child's exact bound may re-admit at or below that
    # cushion without weakening the held accounting. A reservation outside a
    # shape still requires the exact amount.
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
    readmission_id = reservation_id if existing.get("status") == "reserved" else None
    return existing, readmission_id


def command_capacity_reserve(env, args):
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    candidate = specialized_reservation_from_args(args)
    reservation_id = candidate["reservation_id"]
    with controller_lock(env):
        state = load_state(env)
        refuse_retired_capacity_fence(state, candidate["fence_binding"])
        existing, _ = matching_capacity_reservation(state, candidate)
        if existing is None:
            state["capacity_reservations"][reservation_id] = candidate
            save_state(env, state)
    # Azure inventory can take minutes. The queued reservation above makes
    # this attempt durable while leaving the controller lock available to
    # unrelated admissions, releases, status reads, and cleanup.
    inventory = None
    inventory_error = None
    try:
        inventory = provider_call(env, "inventory")["inventory"]
    except LifecycleError as exc:
        inventory_error = str(exc)
    with controller_lock(env):
        state = load_state(env)
        refuse_retired_capacity_fence(state, candidate["fence_binding"])
        candidate, readmission_id = matching_capacity_reservation(state, candidate)
        if candidate is None:
            raise LifecycleError("capacity reservation disappeared during inventory inspection")
        actual = None
        forecast = None
        override_day = None
        try:
            if inventory_error is not None:
                raise LifecycleError(inventory_error)
            state["last_metrics"] = metrics_from_inventory(inventory)
            actual = inventory["metrics"].get("actual_usd")
            forecast = inventory["metrics"].get("forecast_usd")
            # The C3 daily bound gates NEW reservation admissions exactly like
            # create/resume: the disposable runner reserves automatically, so
            # an ungated lane could quietly burn past the bound with no human.
            # A lineage re-admission of an already-reserved constituent is
            # already-held accounting, not new spend, and skips the gate.
            bound_refusal = None
            if readmission_id is None:
                bound_refusal, override_day = daily_bound_refusal(env, state, actual)
            if bound_refusal is not None:
                admitted, reason = False, bound_refusal
            else:
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
            if override_day is not None:
                record_daily_override_use(env, state, actual, override_day)
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
        "forecast_usd": reported_forecast(admitted, actual, forecast),
        "admission_limit_usd": budget_limit(env),
        "daily_bound_override": override_day if admitted else None,
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
        refuse_retired_capacity_fence(state, args.fence_binding)
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
        override_day = None
        if pending:
            pending_ids = frozenset(entry["reservation_id"] for entry in pending)
            try:
                inventory = provider_call(env, "inventory")["inventory"]
                state["last_metrics"] = metrics_from_inventory(inventory)
                actual = inventory["metrics"].get("actual_usd")
                forecast = inventory["metrics"].get("forecast_usd")
                # Same C3 gate as capacity-reserve, once for the whole
                # all-or-nothing shape: only not-yet-held constituents are
                # pending here, so already-reserved ones never re-enter it.
                bound_refusal, override_day = daily_bound_refusal(env, state, actual)
                if bound_refusal is not None:
                    admitted, reason = False, bound_refusal
                else:
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
                if override_day is not None:
                    record_daily_override_use(env, state, actual, override_day)
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
        "forecast_usd": reported_forecast(admitted, actual, forecast),
        "admission_limit_usd": budget_limit(env),
        "daily_bound_override": override_day if admitted else None,
    }, sort_keys=True, separators=(",", ":")))


def matching_capacity_release(state, reservation_id, fence, receipt):
    reservation = state["capacity_reservations"].get(reservation_id)
    if reservation is None:
        raise LifecycleError("capacity release has no exact durable reservation")
    if reservation.get("fence_binding") != fence:
        raise LifecycleError("capacity release fence binding is not exact")
    if reservation.get("status") == "released":
        if reservation.get("cleanup_receipt") != receipt:
            raise LifecycleError("capacity reservation already has a different cleanup receipt")
        return reservation, True
    if reservation.get("status") not in ("queued", "reserved"):
        raise LifecycleError("capacity reservation status is not releasable")
    return reservation, False


def command_capacity_release(env, args):
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    reservation_id = require_id("capacity reservation id", args.reservation_id)
    fence = require_binding("capacity reservation fence", args.fence_binding)
    receipt = require_binding("capacity cleanup receipt", args.cleanup_receipt)
    with controller_lock(env):
        state = load_state(env)
        _, already_released = matching_capacity_release(
            state, reservation_id, fence, receipt
        )
        if already_released:
            print("capacity reservation already released with exact zero-compute proof")
            return
    # Azure inventory is a multi-minute read. It proves compute absence, but
    # it does not need exclusive access to the durable controller document.
    inventory = provider_call(env, "inventory")["inventory"]
    with controller_lock(env):
        state = load_state(env)
        reservation, already_released = matching_capacity_release(
            state, reservation_id, fence, receipt
        )
        if already_released:
            print("capacity reservation already released with exact zero-compute proof")
            return
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


def exact_provider_capacity_identity(reservation, provider):
    return (
        isinstance(reservation, dict)
        and reservation.get("schema") == CAPACITY_RESERVATION_SCHEMA
        and reservation.get("reservation_id") == provider.get("reservation_id")
        and reservation.get("role") == provider.get("role")
        and reservation.get("sku") == provider.get("sku")
        and str(reservation.get("sku_family", "")).lower()
        == str(provider.get("sku_family", "")).lower()
        and reservation.get("vcpus") == provider.get("vcpus")
        and not isinstance(reservation.get("amount_usd"), bool)
        and isinstance(reservation.get("amount_usd"), (int, float))
        and not isinstance(provider.get("amount_usd"), bool)
        and isinstance(provider.get("amount_usd"), (int, float))
        and math.isclose(
            float(reservation["amount_usd"]), float(provider["amount_usd"]),
            rel_tol=0.0, abs_tol=1e-6,
        )
    )


def command_capacity_retire_fence(env, args):
    """Atomically close a released fence against every future admission.

    Provider inventory and the complete same-fence ledger census occur while
    the shared controller lock excludes both reservation entry points. The v2
    retirement tombstone is committed before that lock opens, so successful
    return is the irreversible admission barrier an artifact purge can rely on.
    """
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    fence = require_binding("capacity reservation fence", args.fence_binding)
    receipt = require_binding("capacity fence retirement receipt", args.retirement_receipt)
    reservation_ids = sorted(set(
        require_id("retired capacity reservation id", value)
        for value in args.reservation_id
    ))
    if len(reservation_ids) != len(args.reservation_id) or len(reservation_ids) > 256:
        raise LifecycleError("capacity fence retirement reservation ids are not exact and distinct")
    expected = {
        "schema": CAPACITY_FENCE_RETIREMENT_SCHEMA,
        "fence_binding": fence,
        "reservation_ids": reservation_ids,
        "retirement_receipt": receipt,
    }
    with controller_lock(env):
        state = load_state(env)
        prior = state["retired_capacity_fences"].get(fence)
        if prior is not None and any(prior.get(key) != value for key, value in expected.items()):
            raise LifecycleError("capacity fence already has a different retirement identity")
        allowed = set(reservation_ids)
        same_fence = {
            reservation_id: reservation
            for reservation_id, reservation in state["capacity_reservations"].items()
            if isinstance(reservation, dict) and reservation.get("fence_binding") == fence
        }
        outside = sorted(set(same_fence) - allowed)
        if outside:
            raise LifecycleError(
                "capacity fence retirement census found an unplanned reservation: {}".format(
                    outside[0]
                )
            )
        for reservation_id, reservation in same_fence.items():
            if (
                reservation.get("reservation_id") != reservation_id
                or reservation.get("status") != "released"
                or not HEX_BINDING.match(str(reservation.get("cleanup_receipt", "")).split(":")[-1])
            ):
                raise LifecycleError(
                    "capacity fence retirement requires every exact reservation released"
                )
        inventory = provider_call(env, "inventory")["inventory"]
        provider_reservations = inventory.get("capacity_reservations")
        if not isinstance(provider_reservations, list):
            raise LifecycleError("provider capacity inventory is malformed")
        for provider in provider_reservations:
            if not isinstance(provider, dict) or provider.get("active") is not True:
                continue
            reservation_id = provider.get("reservation_id")
            controller = state["capacity_reservations"].get(reservation_id)
            if not exact_provider_capacity_identity(controller, provider):
                raise LifecycleError(
                    "provider-active capacity lacks exact controller identity during fence retirement"
                )
            if reservation_id in allowed or controller.get("fence_binding") == fence:
                raise LifecycleError(
                    "provider still observes active capacity on the retiring fence"
                )
        if prior is None:
            state["retired_capacity_fences"][fence] = dict(expected, retired_at=iso_utc())
            save_state(env, state)
            print("specialized capacity fence retired after exact release census")
        else:
            print("specialized capacity fence already retired with exact identity")


# What an ORDINARY crewmate payload may contain: the repository as a
# credential-free bundle, plus the one task file its entrypoint reads. This set
# is deliberately NOT widened for the compartment lane; see below.
PAYLOAD_FILE_BOUNDS = {
    "repo.bundle": 512 * 1024 * 1024,
    "brief.md": 256 * 1024,
}
PAYLOAD_REQUIRED = ("repo.bundle", "brief.md")
# What a SECONDMATE COMPARTMENT payload may contain: the ordinary set plus the
# two files bin/fm-spawn.sh stages only for KIND=secondmate - the session runner
# and the spawn-intent pi extension, which the compartment monitor's leg argv
# names by path at /mnt/task/.fm-task/. Bounds are the smallest round numbers
# leaving real headroom over the measured sizes (45142 B and 3867 B on the
# azaccept compartment): a bound is a security control, so headroom buys against
# ordinary source growth, not against a file becoming a different KIND of thing.
COMPARTMENT_PAYLOAD_FILE_BOUNDS = {
    **PAYLOAD_FILE_BOUNDS,
    "fm-secondmate-session.py": 256 * 1024,
    "fm-secondmate-spawn.pi-ext.ts": 64 * 1024,
}
# Both are REQUIRED, not merely admitted: the leg argv runs the runner and
# passes --pi-ext, so a compartment whose staging silently lost either file
# would dispatch a leg that cannot work. Refuse at the controller instead.
COMPARTMENT_PAYLOAD_REQUIRED = PAYLOAD_REQUIRED + (
    "fm-secondmate-session.py",
    "fm-secondmate-spawn.pi-ext.ts",
)
NO_MISTAKES_PAYLOAD_FILE_BOUNDS = {
    **PAYLOAD_FILE_BOUNDS,
    "runtime.tar.gz": 1024 * 1024 * 1024,
}
NO_MISTAKES_PAYLOAD_REQUIRED = PAYLOAD_REQUIRED + ("runtime.tar.gz",)
ACCOUNT_TOTAL_BOUND = 1024 * 1024


def payload_contract(role):
    """The one owner of "what may a payload for this lane contain".

    Returns (bounds, required) for the worker's durable role. Splitting by lane
    rather than flattening one set keeps the ordinary crewmate lane exactly as
    narrow as it is today: an author worker that somehow staged a session
    runner is still refused.
    """
    if role == "secondmate":
        return COMPARTMENT_PAYLOAD_FILE_BOUNDS, COMPARTMENT_PAYLOAD_REQUIRED
    if role == "no-mistakes":
        return NO_MISTAKES_PAYLOAD_FILE_BOUNDS, NO_MISTAKES_PAYLOAD_REQUIRED
    return PAYLOAD_FILE_BOUNDS, PAYLOAD_REQUIRED


def staged_directory_manifest(label, directory, bounds=None, total_bound=None, required=()):
    """Digest one flat staging directory into {name: {sha256, bytes}}.

    The manifest (not the file paths) enters the digest-bound execution
    request, so the guest can verify every staged byte; the provider carries
    the local directory separately for transport.
    """
    root = Path(directory)
    if root.is_symlink() or not root.is_dir():
        raise LifecycleError("{} staging directory is unavailable: {}".format(label, directory))
    manifest = {}
    total = 0
    for entry in sorted(root.iterdir()):
        if entry.name.startswith("."):
            continue
        if entry.is_symlink() or not entry.is_file():
            raise LifecycleError("{} staging entry is not a regular file: {}".format(label, entry.name))
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", entry.name):
            raise LifecycleError("{} staging entry name is unsupported: {}".format(label, entry.name))
        body = entry.read_bytes()
        bound = (bounds or {}).get(entry.name)
        if bounds is not None and bound is None:
            raise LifecycleError("{} staging entry is not in the reviewed set: {}".format(label, entry.name))
        if bound is not None and len(body) > bound:
            raise LifecycleError("{} staging entry exceeds its byte bound: {}".format(label, entry.name))
        total += len(body)
        manifest[entry.name] = {
            "sha256": hashlib.sha256(body).hexdigest(),
            "bytes": len(body),
        }
    if not manifest:
        raise LifecycleError("{} staging directory is empty: {}".format(label, directory))
    for name in required:
        if name not in manifest:
            raise LifecycleError("{} staging directory lacks required {}".format(label, name))
    if total_bound is not None and total > total_bound:
        raise LifecycleError("{} staging directory exceeds its total byte bound".format(label))
    return manifest


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
    if (args.payload_dir is None) != (args.account_dir is None):
        raise LifecycleError("payload and account staging directories travel together or not at all")
    if args.existing_task_disk and args.payload_dir is not None:
        raise LifecycleError("existing task-disk recovery cannot replace payload or account state")
    if args.outcome_dir is not None and args.payload_dir is None and not args.existing_task_disk:
        raise LifecycleError("an outcome can only be collected from a staged repository or an explicitly retained repository")
    if args.return_kind is not None and args.outcome_dir is None:
        raise LifecycleError("an authorized task return requires an outcome directory")
    if args.existing_task_disk and (args.outcome_dir is None or args.return_kind is None):
        raise LifecycleError("existing task-disk recovery requires an authorized return outcome")
    if args.outcome_dir is not None:
        outcome_root = Path(args.outcome_dir)
        if outcome_root.is_symlink() or not outcome_root.is_dir():
            raise LifecycleError("outcome directory is unavailable: {}".format(args.outcome_dir))
    payload_manifest = account_manifest = None
    inventory = provider_call(env, "inventory")["inventory"]
    with contextlib.ExitStack() as stack:
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
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("execute refuses a non-assigned or ambiguous worker: {}".format(reason))
        if args.payload_dir is not None:
            # The staging contract is chosen by the worker's DURABLE role, so it
            # is resolved here (under the one controller lock, with the queue
            # item and worker record in hand) rather than from the payload's own
            # contents - a payload must never select the rules it is judged by.
            # create_worker_record copies the item's role onto the worker, so a
            # disagreement means the two records have drifted: fail closed.
            worker_role = worker.get("role", "author")
            if worker_role != item.get("role", "author"):
                raise LifecycleError(
                    "execute refuses a worker whose role disagrees with its queue item")
            bounds, required = payload_contract(worker_role)
            payload_manifest = staged_directory_manifest(
                "payload", args.payload_dir, bounds=bounds, required=required,
            )
            account_manifest = staged_directory_manifest(
                "account", args.account_dir, total_bound=ACCOUNT_TOTAL_BOUND,
            )
        request = {
            "schema": EXECUTION_SCHEMA,
            **worker["bindings"],
            "cloud_instance_id": worker["cloud_instance_id"],
            "argv": argv,
            "wall_seconds": args.wall_seconds,
        }
        if payload_manifest is not None:
            request["payload_files"] = payload_manifest
            request["account_files"] = account_manifest
        if args.existing_task_disk:
            try:
                supervisor_body = WORKER_SUPERVISOR.read_bytes()
            except OSError as exc:
                raise LifecycleError(
                    "existing task-disk recovery supervisor is unreadable: {}".format(exc)
                ) from None
            request["existing_task_disk"] = True
            request["supervisor_sha256"] = hashlib.sha256(supervisor_body).hexdigest()
        if args.outcome_dir is not None:
            # Digest-bound, so withholding the staging URL downstream cannot
            # silently turn a landing task into a fire-and-forget one: the
            # guest refuses instead.
            request["outcome_expected"] = True
        if args.return_kind is not None:
            report_name = "completion.md" if args.return_kind == "ship" else "report.md"
            request["return_contract"] = {
                "schema": "fm.worker-return-contract/v1",
                "kind": args.return_kind,
                "report_required": True,
                "report_path": "data/{}/{}".format(args.task, report_name),
                "status_path": "state/{}.status".format(args.task),
                "visuals_path": "data/{}/visuals".format(args.task),
                "branch": "fm/{}".format(args.task) if args.return_kind == "ship" else "",
            }
        if worker.get("role") == "no-mistakes":
            if args.outcome_dir is None:
                raise LifecycleError("a no-mistakes execution requires an outcome directory")
            request["worker_role"] = "no-mistakes"
            request["service_return_contract"] = {
                "schema": "fm.no-mistakes-worker-return/v1",
                "step_outcome_path": "outcome.json",
                "step_outcome_max_bytes": 1024 * 1024,
            }
        request["request_digest"] = digest_value(request)
        existing = state["executions"].get(request["request_digest"])
        if existing is not None:
            print(json.dumps(existing, sort_keys=True, separators=(",", ":")))
            return
        # Every field the provider will see has to be present BEFORE the key is
        # minted: make_action hashes the whole action as its last step, and the
        # provider recomputes that hash over what it actually receives. Adding
        # these afterwards made the two disagree, so any execute carrying a
        # payload or an outcome sink was refused outright with "provider
        # mutation idempotency key is not exact". A bare digest-bound argv had
        # none of these fields, which is why the earlier smoke passed and the
        # first crewmate could never run.
        staged = {}
        if payload_manifest is not None:
            staged["payload_dir"] = str(Path(args.payload_dir).resolve())
            staged["account_dir"] = str(Path(args.account_dir).resolve())
        if args.outcome_dir is not None:
            staged["outcome_dir"] = str(Path(args.outcome_dir).resolve())
        action = make_action(
            env, "execute", worker=worker, request=request,
            request_digest=request["request_digest"], **staged,
        )
        lease = stack.enter_context(slot_lease(env, worker["slot"]))
        claim_pending(env, state, action)
      mutation = provider_mutate(env, action, lease)
      with controller_lock(env):
        applied = apply_pending(env, action, mutation)
        result = applied["executions"][request["request_digest"]]
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def command_authority_receipt(env, args):
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        worker = state["workers"].get(str((item or {}).get("slot")))
        if item is None or worker is None or worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("authority receipt requires one exact assigned worker")
        authority_worker = worker_authority_snapshot(worker, item)
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False) as handle:
            json.dump(authority_worker, handle, sort_keys=True, separators=(",", ":"))
            worker_path = handle.name
        try:
            result = subprocess.run([
                "python3", str(ROOT / "bin" / "fm-worker-authority.py"),
                "--home", str(authority_home(env, worker)), "--task", args.task,
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
        live_children = sum(
            1 for entry in state["queue"].values()
            if entry.get("parent_task") == args.task
            and entry.get("parent_task_generation") == args.task_generation
            and entry.get("status") != "complete"
        )
        if live_children:
            # A parent cannot release out from under live children; this sits
            # here, under the one lock with the whole queue in hand, because
            # the authority tool reads controller state lock-free.
            raise LifecycleError(
                "release refuses: {} active children name parent {}".format(live_children, args.task))
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


def command_service_complete(env, args):
    """Release a service assignment from execution evidence the lifecycle owns.

    Ordinary crewmates return through task reports and landing receipts.  A
    no-mistakes worker instead returns a digest-bound service envelope to its
    controller, so asking it to manufacture ordinary task authority would be
    ceremony and, worse, a false claim.  This narrow role-owned boundary only
    accepts an execution already stored under the exact assigned worker.
    """
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError(
            "--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    request_digest = require_binding("execution request digest", args.request_digest)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(
            require_id("task", args.task),
            require_id("task generation", args.task_generation),
        )
        item = state["queue"].get(key)
        if item is None or item.get("role") != "no-mistakes":
            raise LifecycleError("service completion is owned by no-mistakes workers only")
        execution = state["executions"].get(request_digest)
        if not isinstance(execution, dict):
            raise LifecycleError("service completion has no exact recorded execution")
        receipt = item.get("service_completion_receipt")
        if receipt is not None:
            if item.get("status") not in ("releasing", "complete"):
                raise LifecycleError("service completion receipt exists in an invalid queue state")
            if not isinstance(receipt, dict):
                raise LifecycleError("service completion receipt is malformed")
            unsigned_receipt = dict(receipt)
            receipt_digest = unsigned_receipt.pop("proof_digest", None)
            if (
                receipt.get("schema") != "fm.worker-service-release/v1"
                or receipt.get("task") != args.task
                or receipt.get("task_generation") != args.task_generation
                or receipt.get("assignment_generation") != args.assignment_generation
                or receipt.get("request_digest") != request_digest
                or receipt.get("result_digest") != execution.get("result_digest")
                or execution.get("request_digest") != request_digest
                or execution.get("assignment_generation") != args.assignment_generation
                or receipt.get("verdict") != "proved"
                or receipt_digest != digest_value(unsigned_receipt)
            ):
                raise LifecycleError("service completion receipt identity differs")
            worker = state["workers"].get(str(item.get("slot")))
            worker_owns_item = (
                worker is not None and worker.get("queue_key") == key
            )
            if item.get("status") == "releasing" and not worker_owns_item:
                raise LifecycleError("releasing service completion lost its exact worker")
            if worker_owns_item and (
                worker.get("role") != "no-mistakes"
                or worker.get("assignment_generation") != args.assignment_generation
                or worker.get("release_proof") != receipt
            ):
                raise LifecycleError("service completion worker receipt identity differs")
            print("service release proof already recorded with exact identity")
            return
        worker = state["workers"].get(str(item.get("slot")))
        if item.get("status") != "assigned" or worker is None:
            raise LifecycleError("service completion requires one exact assigned worker")
        if worker.get("role") != "no-mistakes":
            raise LifecycleError("service completion is owned by no-mistakes workers only")
        if worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("service completion assignment generation is not exact")
        if (
            execution.get("request_digest") != request_digest
            or execution.get("result_digest") != worker.get("last_execution_digest")
            or execution.get("assignment_generation") != args.assignment_generation
        ):
            raise LifecycleError("service completion execution identity differs")
        proof = {
            "schema": "fm.worker-service-release/v1",
            **worker["bindings"],
            "assignment_generation": args.assignment_generation,
            "cloud_instance_id": worker["cloud_instance_id"],
            "resources": worker["resources"],
            "request_digest": request_digest,
            "result_digest": execution["result_digest"],
            "verdict": "proved",
        }
        proof["proof_digest"] = digest_value(proof)
        held = worker.get("release_proof")
        if held is not None:
            if held != proof:
                raise LifecycleError("worker already has a different service release proof")
            print("service release proof already recorded with exact identity")
            return
        worker["release_proof"] = copy.deepcopy(proof)
        worker["released_at"] = iso_utc()
        worker["phase"] = "release-proved"
        item["service_completion_receipt"] = copy.deepcopy(proof)
        item["status"] = "releasing"
        save_state(env, state)
    print("service execution proved; exact idle capacity is eligible for cleanup")


def command_withdraw(env, args):
    """Retire a projecting or queued request that no worker ever took.

    A task can finish, be cancelled, or be superseded locally long before any
    cloud capacity is built for it, and its queue entry then keeps counting as
    demand: reconcile sees eligible depth and builds a worker for work that is
    already done. That is not merely wasted spend. Re-running a task that has
    side effects outside this fleet, posting or sending or filing, repeats them.

    It also retires a `projecting` request whose process died after the queue
    took ownership but before the assignment-private snapshot completed.

    `release` cannot cover this: it requires an ASSIGNED item with a durable
    worker owner and a release proof describing that worker. An entry that was
    never assigned has neither, so before this command the only way to clear one
    was to hand-edit controller state.
    """
    require_id("task", args.task)
    require_id("task generation", args.task_generation)
    if not args.confirm_withdraw:
        raise LifecycleError("--confirm-withdraw is required")
    # Every other mutating subcommand demands this, and withdraw deletes
    # durable state, so it does not get to be the lenient one.
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    with controller_lock(env):
        state = load_state(env)
        key = request_key(args.task, args.task_generation)
        item = state["queue"].get(key)
        if item is None:
            raise LifecycleError("withdraw requires one exact queued task generation")
        status = item.get("status")
        if status not in ("queued", "projecting"):
            # Anything past the queue has cloud capacity or a live assignment
            # behind it, and dropping the entry would strand that worker with no
            # queue owner. Those go out through release.
            # `release` only accepts `assigned`, so pointing a `complete` or
            # `releasing` entry at it would be impossible advice.
            # `release` only accepts `assigned`. `assigning` still counts as
            # demand (desired_count includes it) and can persist for hours
            # behind a slow create, so calling it "past the queue" is false.
            if status == "assigned":
                remedy = "release it instead"
            elif status == "assigning":
                remedy = "a create is in flight for it; reconcile first"
            else:
                remedy = "it is past the queue and release cannot take it either"
            raise LifecycleError(
                "withdraw refuses a task generation that is already {}; {}".format(status, remedy)
            )
        for worker in state["workers"].values():
            if worker.get("queue_key") == key:
                raise LifecycleError("withdraw refuses a task generation a worker still owns")
        # An in-flight or wedged action names its queue owner. Deleting the
        # entry out from under it does not fail loudly: the next reconcile
        # replays the pending action, apply_action_result cannot find the owner
        # and raises, and because the pending action never clears, that repeats
        # forever. One stale entry would take the whole fleet's convergence
        # with it.
        for slot_key in sorted(state.get("pending_actions") or {}, key=int):
            pending = state["pending_actions"][slot_key]
            pending_request = pending.get("request") or {}
            pending_bindings = pending.get("bindings") or {}
            for candidate in (pending_request, pending_bindings):
                if candidate.get("task") is None:
                    continue
                if request_key(candidate["task"], candidate["task_generation"]) == key:
                    raise LifecycleError(
                        "withdraw refuses a task generation a pending {} action on slot {} "
                        "still names; reconcile it first".format(
                            pending.get("type", "provider"), slot_key)
                    )
        withdrawn = item
        # This request never held provider capacity, so its projection is the
        # only controller-owned assignment artifact.  Remove exactly that
        # private directory before deleting its durable owner; a same-profile
        # request lives at another projection binding and is not inspected.
        cleanup_placement_projection(env, withdrawn)
        del state["queue"][key]
        save_state(env, state)
    # A machine-readable receipt naming the exact entry that was deleted. The
    # wrapper keys its cloud-state cleanup off THIS line, not off the exit
    # code: `--help` also exits 0 without withdrawing anything, and gating on
    # the exit code let `withdraw --task <id> --help` destroy a live task's
    # staged credential, payload and returned result.
    print("FM-WITHDREW {} {}".format(args.task, args.task_generation))
    write_task_home_receipt(getattr(args, "task_home_out", None), withdrawn)
    print("withdrew queued request {}".format(key))


def write_task_home_receipt(path, item, worker=None):
    """Record the authorized task home for a removal, on its own channel.

    A compartment child's cloud state, including its plaintext provider
    credential, is staged in the SECONDMATE's home, while withdraw and
    surrender necessarily run with FM_HOME on the primary because the
    controller document has exactly one home. The wrapper therefore cannot know
    where to remove from, and must not guess from the task id: ids are
    home-scoped, so the same id can be live in two homes at once. The
    controller does know, having authorized this exact path for this exact task
    generation under its own lock.

    A DEDICATED FILE, not a line in stdout. Carrying it on the command's own
    output made the value depend on two unrelated invariants holding forever:
    that the wrapper never captures stderr into the same stream, and that no id
    can contain a space or a newline. Either one relaxing would let another
    line decide where a removal is aimed. A file has one writer and one reader.

    The QUEUE ITEM is the source, never the worker record: both carry
    task_home, but only the item carries parent_task, and the parent is what
    lets the wrapper hold the home to the same marker-content check the spawn
    held FM_SPAWN_TASK_HOME to.
    """
    if not path:
        return
    item = item or {}
    task_home = item.get("task_home")
    parent = item.get("parent_task")
    if not (isinstance(task_home, str) and task_home.startswith("/")
            and isinstance(parent, str) and parent):
        return
    # A worker record that disagrees with its own queue item means the two
    # halves of one admission diverged. Write nothing rather than pick a side:
    # the fallback leaves a credential to be found, while following the wrong
    # half would remove state in a home this task does not live in.
    #
    # Same doctrine as command_execute's role check, which refuses outright
    # when worker["role"] disagrees with the item's. Both read a drifted pair
    # as untrustworthy and both fail closed; they differ only in what closed
    # means for their lane. Execute must not run, so it raises. A removal that
    # does not happen is a credential left on disk to be found, so this one
    # declines the redirect and lets the caller fall back rather than aiming a
    # deletion with half of a disagreement. Neither guard can admit a state the
    # other refuses: they read different fields on different commands, and
    # neither ever widens what the other allows.
    held = (worker or {}).get("task_home")
    if held is not None and held != task_home:
        return
    # Named fail path: this runs AFTER the receipt is printed and after
    # save_state, so an unwritable channel raises with the task already
    # withdrawn or surrendered and no removal performed. The wrapper's own
    # surviving-credential check does not see it either, because the fallback
    # home is empty. It needs an unwritable TMPDIR, which the wrapper's own
    # mktemp would have failed on first, so it is exotic rather than reachable;
    # it is written down because the file channel is what introduced it.
    #
    # The file is two lines exactly, so the reader needs no parser. A value
    # that cannot survive that shape is not written at all.
    if "\n" in parent or "\n" in task_home or "\r" in parent or "\r" in task_home:
        return
    Path(path).write_text("{}\n{}\n".format(parent, task_home), encoding="utf-8")


def worker_authority_snapshot(worker, item):
    """Add controller-owned placement identity to an authority subprocess.

    The queue entry is the durable account lease; task metadata only records
    where fm-spawn staged it. Keep the authority input ephemeral so existing
    live worker records gain this proof without a state-schema migration.
    """
    snapshot = dict(worker)
    snapshot["account_lease"] = {
        "account_home": item.get("account_home"),
        "account_profile": item.get("account_profile"),
    }
    return snapshot


def ordinary_authority_attempt(env, args, worker, item):
    """Run the ordinary release authority; None on success, its refusal text otherwise."""
    authority_worker = worker_authority_snapshot(worker, item)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", delete=False) as handle:
        json.dump(authority_worker, handle, sort_keys=True, separators=(",", ":"))
        worker_path = handle.name
    output_path = worker_path + ".receipt"
    try:
        result = subprocess.run([
            "python3", str(ROOT / "bin" / "fm-worker-authority.py"),
            "--home", str(authority_home(env, worker)), "--task", args.task,
            "--task-generation", args.task_generation,
            "--assignment-generation", worker["assignment_generation"],
            "--worker-state", worker_path, "--output", output_path,
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=PROVIDER_TIMEOUT_SECONDS)
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(worker_path).unlink()
        with contextlib.suppress(FileNotFoundError):
            Path(output_path).unlink()
    if result.returncode == 0:
        return None
    stderr_text = result.stderr.decode("utf-8", errors="replace").strip()
    # Only a genuine refusal unlocks surrender. The authority also exits
    # nonzero on tool or environment trouble (broken git, unreadable helper),
    # and treating that as a refusal would make every dark worker
    # surrenderable exactly when the machine is least trustworthy.
    if "WORKER AUTHORITY REFUSED" not in stderr_text:
        raise LifecycleError(
            "ordinary release authority tool failed rather than refusing: {}".format(stderr_text[-500:])
        )
    return stderr_text[-1000:]


def command_surrender(env, args):
    """Release an assigned worker whose ordinary release authority is unrecoverable.

    The ordinary lane is authority-receipt -> release: five receipts minted from
    the live task metadata, endpoint oracle, landing graph, account directory,
    and worktree. A task can lose that authority legitimately - local teardown
    consumed state/<task>.meta before any receipt existed - and the worker slot
    is then stranded: release requires a proof nothing can mint, withdraw only
    takes queued entries, and the only remaining path was hand-editing
    controller state.

    Surrender is the durable, refusal-first replacement for that hand edit. It
    is not a shortcut around release: it first runs the ordinary authority
    itself and refuses when that succeeds, refuses live compute (the VM must be
    deallocated or stopped), refuses to replace an ordinary release proof,
    refuses to orphan live compartment children unless the operator passes
    --confirm-orphan-children (which durably stamps reparented_to: primary on
    every live child under the same lock hold), and demands an operator reason
    plus the same double confirmation as withdraw.
    The minted bundle keeps the fm.worker-release/v2 shape the downstream
    deallocate/delete-compute/reset machinery already fences on, but every
    authority verdict is "surrendered" - release_receipt() rejects that verdict,
    so a surrender bundle can never be replayed through the ordinary release
    command - and a top-level surrender block records the reason and the
    ordinary authority's refusal verbatim.
    """
    require_id("task", args.task)
    require_id("task generation", args.task_generation)
    reason = (args.reason or "").strip()
    if not reason or len(reason) > 1000:
        raise LifecycleError("--reason must be 1..1000 characters of operator explanation")
    if not args.confirm_surrender:
        raise LifecycleError("--confirm-surrender is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    with controller_lock(env):
        state = load_state(env)
        key = request_key(args.task, args.task_generation)
        item = state["queue"].get(key)
        if item is not None and item.get("status") == "complete":
            raise LifecycleError(
                "surrendered task generation already converged; if its staged credential "
                "remains under state/, remove it with fm_cloud_state_remove from "
                "bin/fm-cloud-state-lib.sh"
            )
        if item is None or item.get("status") not in ("assigned", "releasing"):
            raise LifecycleError("surrender requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("queue_key") != key:
            raise LifecycleError("surrender task has no exact durable worker owner")
        if (state.get("pending_actions") or {}).get(str(worker["slot"])) is not None:
            raise LifecycleError("the worker slot has a pending provider action; reconcile it first")
        existing = worker.get("release_proof")
        if existing is not None:
            if isinstance(existing.get("surrender"), dict):
                if (existing.get("task") != args.task
                        or existing.get("task_generation") != args.task_generation):
                    raise LifecycleError("stored surrender proof binds a different task generation")
                write_surrender_output(args.output, existing)
                print("surrender proof already recorded with exact identity")
                print("FM-SURRENDERED {} {}".format(args.task, args.task_generation))
                write_task_home_receipt(
                    getattr(args, "task_home_out", None), item, worker)
                return
            raise LifecycleError("worker already has an ordinary release proof; reconcile releases it")
        if item.get("status") != "assigned":
            raise LifecycleError("surrender requires one exact assigned task generation")
        produced = []
        for request_digest, execution in sorted((state.get("executions") or {}).items()):
            if not isinstance(execution, dict):
                continue
            if (execution.get("task") != args.task
                    or execution.get("task_generation") != args.task_generation
                    or execution.get("assignment_generation") != worker["assignment_generation"]):
                continue
            if (execution.get("outcome_present") is True
                    or execution.get("outcome_uncommitted_changes") is True
                    or (execution.get("outcome_commits") or 0) > 0):
                produced.append(request_digest)
        if produced and not args.confirm_discard_unlanded:
            # The controller's own durable record says this worker produced
            # repository work whose landing is unproven; surrendering it leads
            # to a reset that deletes the task disk holding that work. The
            # operator can override, but only by naming the discard.
            raise LifecycleError(
                "surrender refuses: execution(s) {} produced repository work whose landing "
                "is unproven; inspect the task disk, then pass --confirm-discard-unlanded "
                "to discard it deliberately".format(", ".join(produced))
            )
        # The children-quiesced gate, mirroring command_release's, with the one
        # sanctioned bypass (design B.7 graft 4, closing AMENDMENT 1's
        # temporary hole): orphaning live children demands its own explicit
        # confirmation, and taking it stamps a durable reparented_to note on
        # every live child in the SAME lock hold that records the surrender,
        # so the reparenting and the surrender are one atomic durable fact.
        live_children = [
            entry for entry in state["queue"].values()
            if entry.get("parent_task") == args.task
            and entry.get("parent_task_generation") == args.task_generation
            and entry.get("status") != "complete"
        ]
        if live_children and not args.confirm_orphan_children:
            raise LifecycleError(
                "surrender refuses: {} active children name parent {}; pass "
                "--confirm-orphan-children to reparent them to the primary deliberately".format(
                    len(live_children), args.task))
        refusal = ordinary_authority_attempt(env, args, worker, item)
        if refusal is None:
            raise LifecycleError(
                "ordinary release authority succeeded; use authority-receipt and release"
            )
        inventory = provider_call(env, "inventory")["inventory"]
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, note = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("surrender refuses a non-assigned or ambiguous worker: {}".format(note))
        power = str(((cloud.get("resources") or {}).get("vm") or {}).get("power_state", "")).lower()
        if "deallocated" not in power and "stopped" not in power:
            raise LifecycleError(
                "surrender requires dark compute; the worker VM power state is {!r}".format(power or "unknown")
            )
        surrendered_at = iso_utc()
        surrender = {
            "reason": reason,
            "ordinary_refusal": refusal,
            "surrendered_at": surrendered_at,
            "power_state": power,
            "last_execution_digest": worker.get("last_execution_digest"),
            "discarded_unlanded_executions": produced,
        }
        if live_children:
            # Scoped deliberately: an ordinary childless surrender must mint
            # BYTE-IDENTICAL receipts to before this change, and every receipt's
            # evidence_digest is taken over this block, so an unconditional
            # "orphaned_children": 0 would move all five digests on a lane that
            # never orphaned anything.
            surrender["orphaned_children"] = len(live_children)
        proof = {
            "schema": RELEASE_SCHEMA,
            "home_binding": worker["bindings"]["home_binding"],
            "task": args.task,
            "task_generation": args.task_generation,
            "assignment_generation": worker["assignment_generation"],
            "account_binding": worker["bindings"]["account_binding"],
            "worktree_binding": worker["bindings"]["worktree_binding"],
            "repository_binding": worker["bindings"]["repository_binding"],
            "repository_generation": worker["bindings"]["repository_generation"],
            "cloud_instance_id": worker["cloud_instance_id"],
            "resources": worker["resources"],
            "surrender": surrender,
            "authorities": {},
        }
        for name in ("endpoint", "report", "landing", "account", "worktree"):
            receipt_value = {
                "schema": AUTHORITY_SCHEMA,
                "authority": name,
                "task": args.task,
                "task_generation": args.task_generation,
                "assignment_generation": worker["assignment_generation"],
                "verdict": "surrendered",
                "evidence_digest": digest_value({"authority": name, "surrender": surrender}),
            }
            receipt_value["receipt_digest"] = digest_value(receipt_value)
            proof["authorities"][name] = receipt_value
        proof["proof_digest"] = digest_value(proof)
        worker["release_proof"] = proof
        worker["released_at"] = surrendered_at
        worker["phase"] = "release-proved"
        item["status"] = "releasing"
        for entry in live_children:
            # Durable, under this same lock hold: the child queue entries now
            # name the primary as their driver. The parent fields stay for
            # lineage; the note is what the captain reads.
            entry["reparented_to"] = "primary"
        save_state(env, state)
    write_surrender_output(args.output, proof)
    print("FM-SURRENDERED {} {}".format(args.task, args.task_generation))
    write_task_home_receipt(getattr(args, "task_home_out", None), item, worker)
    print("surrendered release recorded; reconcile now owns deallocation, compute deletion, and reset")


def write_surrender_output(path, proof):
    Path(path).write_text(
        json.dumps(proof, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8"
    )


def command_abandon_claim(env, args):
    """Retire one slot's unapplied claim after proving its mutation is complete.

    The lock discipline removed the old, unsafe exit from a wedged claim: a
    second execute used to blind-overwrite the first, silently discarding its
    replay obligation and running the guest twice. The sanctioned exit must
    exist, because an apply can refuse a provider result deterministically
    (a version-skewed supervisor answering an outcome-expected execute with no
    outcome disposition is the recorded case), and the planner deliberately
    skips a claimed slot, so release, reset, and every other lane stays
    blocked behind the claim forever.

    This command takes the slot lease (no live owner), REPLAYS the claim
    itself and requires the provider result to bind the exact idempotency key
    - proving the mutation is complete at the provider and its result is
    final under key-idempotency - then attempts the ordinary apply. The proof
    is obtained BY submitting: for a claim that never reached the provider,
    the replay IS the first submission (abandoning a create builds the VM),
    because dropping a claim of unknown provider-side status could strand a
    resource that exists and is billing. An abandoned refused create leaves
    its cloud resources to the ordinary planner, which now sees the slot. An apply
    that succeeds ends the claim normally. A script-bound terminal execution
    whose apply refuses is recorded with its result digest before clearing,
    but only when it names the task-command resource in the claimed action; a
    foreign terminal resource identity retains the claim.
    An exact-key ProviderIdentityRefused replay is recorded verbatim before
    clearing because that recorded resource identity can never bind again.
    The one crash-before-submit exception uses the provider's distinct
    abandon-execute operation: two fresh Azure views must bracket a durable
    marker and prove the empty command never started before its exact child is
    deleted. Every other provider failure leaves the claim untouched.
    """
    if not args.confirm_abandon:
        raise LifecycleError("--confirm-abandon is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    slot = str(args.slot)
    if not slot.isdigit():
        raise LifecycleError("abandon-claim requires one exact decimal slot")
    with controller_lock(env):
        state = load_state(env)
        action = (state.get("pending_actions") or {}).get(slot)
        if not isinstance(action, dict):
            raise LifecycleError("slot {} holds no unapplied claim".format(slot))
        if action.get("idempotency_key") != args.idempotency_key:
            raise LifecycleError(
                "slot {} holds a different claim; pass its exact idempotency key".format(slot))
    with slot_lease(env, slot) as lease:
        # The pre-lease read may be stale: a drain can have applied and
        # cleared this claim between the check above and this lease. Re-read
        # under the lease before re-sending, exactly as the drain does, so an
        # already-applied key is never mutated again without a durable claim
        # naming it.
        with controller_lock(env):
            current = (load_state(env).get("pending_actions") or {}).get(slot)
        if not isinstance(current, dict) or current.get("idempotency_key") != action["idempotency_key"]:
            raise LifecycleError("slot {} claim changed while abandoning; retry".format(slot))
        identity_refusal = None
        replay_failure = None
        try:
            result = provider_mutate(env, action, lease)
        except ProviderIdentityRefused as exc:
            identity_refusal = exc
        except LifecycleError as exc:
            replay_failure = exc
        if replay_failure is not None and action.get("type") == "execute":
            try:
                result = provider_abandon_execute(env, action, lease)
            except (LifecycleError, ProviderIdentityRefused):
                raise replay_failure
            validate_abandon_execute_result(action, result)
            with controller_lock(env):
                clean = load_state(env)
                current = (clean.get("pending_actions") or {}).get(slot)
                if (
                    not isinstance(current, dict)
                    or current.get("idempotency_key") != action["idempotency_key"]
                ):
                    raise LifecycleError(
                        "slot {} claim changed while abandoning; retry".format(slot)
                    )
                worker = clean["workers"].get(slot)
                validate_durable_abandon_execute_worker(action, worker)
                worker["retired_execute_key"] = action["idempotency_key"]
                record_refusal(clean, worker, LifecycleError(
                    "claim abandoned by operator: exact never-started execute retired"
                ))
                clean["pending_actions"].pop(slot, None)
                save_state(env, clean)
            print("FM-ABANDONED-CLAIM {} {}".format(
                slot, action["idempotency_key"]
            ))
            print("never-started execute retired; the slot plans normally again")
            return
        if replay_failure is not None:
            raise replay_failure
        if identity_refusal is not None:
            with controller_lock(env):
                clean = load_state(env)
                current = (clean.get("pending_actions") or {}).get(slot)
                if (
                    not isinstance(current, dict)
                    or current.get("idempotency_key") != action["idempotency_key"]
                ):
                    raise LifecycleError("slot {} claim changed while abandoning; retry".format(slot))
                worker = clean["workers"].get(slot)
                record_refusal(clean, worker, LifecycleError(
                    "claim abandoned by operator: {}".format(identity_refusal)
                ))
                clean["pending_actions"].pop(slot, None)
                save_state(env, clean)
        else:
            with controller_lock(env):
                try:
                    apply_pending(env, action, result)
                    print("claim applied cleanly; nothing was abandoned")
                    return
                except ProviderResultIdentityRefused:
                    raise
                except LifecycleError as exc:
                    refusal = exc
                clean = load_state(env)
                current = (clean.get("pending_actions") or {}).get(slot)
                if (
                    not isinstance(current, dict)
                    or current.get("idempotency_key") != action["idempotency_key"]
                ):
                    raise LifecycleError("slot {} claim changed while abandoning; retry".format(slot))
                worker = clean["workers"].get(slot)
                record_refusal(clean, worker, LifecycleError(
                    "claim abandoned by operator: {} (result digest {})".format(
                        str(refusal)[:400], result.get("result_digest") or digest_value(result))))
                clean["pending_actions"].pop(slot, None)
                save_state(env, clean)
    print("FM-ABANDONED-CLAIM {} {}".format(slot, action["idempotency_key"]))
    print("abandoned claim recorded in cleanup refusals; the slot plans normally again")


def command_resume(env, args):
    if not args.confirm_resume:
        raise LifecycleError("--confirm-resume is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    require_binding("repository binding", args.repository_binding)
    key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
    # A stranded claim on THIS slot must replay before resume can judge the
    # worker, and it must replay strictly: resume's preconditions are only
    # meaningful against fully applied state for this worker. Slot-scoping
    # keeps an unrelated slot's wedged or hours-long replay from blocking or
    # failing this resume; apply only touches the owning slot's compartment.
    with controller_lock(env):
        peek = load_state(env)
        peek_item = peek["queue"].get(key)
        resume_slot = str((peek_item or {}).get("slot", ""))
    if resume_slot.isdigit():
        drain_pending(env, slot=resume_slot, strict=True)
    inventory = provider_call(env, "inventory")["inventory"]
    with contextlib.ExitStack() as stack:
      with controller_lock(env):
        state = load_state(env)
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
        # Resume builds NEW compute for retained disks, so it sits under the
        # same C3 daily spend bound as create; the refusal raises before any
        # worker field is touched.
        bound_refusal, override_day = daily_bound_refusal(
            env, state, inventory["metrics"].get("actual_usd")
        )
        if bound_refusal is not None:
            raise LifecycleError(bound_refusal)
        if override_day is not None:
            # Resume has no further admission gate, so the guard passing IS
            # the admission decision; record the override's effect now.
            record_daily_override_use(
                env, state, inventory["metrics"].get("actual_usd"), override_day
            )
            print(
                "DAILY BOUND OVERRIDE: resume admitted past the {:.2f} USD daily bound "
                "for day {} by FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE".format(
                    env["daily_bound_usd"], override_day))
        for kind in ("vm", "nic", "os-disk"):
            worker.get("resources", {}).pop(kind, None)
        worker["cloud_instance_id"] = None
        previous_cloud_generation = worker["cloud_generation"]
        worker["cloud_generation"] += 1
        worker["phase"] = "resuming"
        extra = {}
        if override_day is not None:
            extra["daily_bound_override"] = override_day
        action = make_action(
            env, "resume", worker=worker, item=item, reuse_retained=True,
            previous_cloud_generation=previous_cloud_generation,
            shared_admission_digest=digest_value({
                "slot": worker["slot"], "sku": worker["sku"], "sku_family": worker["sku_family"],
                "assignment_generation": worker["assignment_generation"],
                "reservation_usd": worker["reservation_usd"],
            }),
            **extra,
        )
        lease = stack.enter_context(slot_lease(env, worker["slot"]))
        claim_pending(env, state, action)
      mutation = provider_mutate(env, action, lease)
      with controller_lock(env):
        apply_pending(env, action, mutation)
    print("replacement generation attached the exact retained task and account disks")


def command_steer(env, args):
    if not args.confirm_steer:
        raise LifecycleError("--confirm-steer is required")
    if args.confirm_subscription != env["subscription"]:
        raise LifecycleError("--confirm-subscription must exactly match FM_AZURE_SUBSCRIPTION_ID")
    request_digest = require_binding("steer request digest", args.request_digest)
    inventory = provider_call(env, "inventory")["inventory"]
    with contextlib.ExitStack() as stack:
      with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("steer requires one exact assigned task generation")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker["assignment_generation"] != args.assignment_generation:
            raise LifecycleError("steer assignment generation is not exact")
        cloud = inventory_by_slot(inventory).get(worker["slot"])
        classification, reason = classify_worker(worker, cloud)
        if classification != "assigned":
            raise LifecycleError("steer refuses a non-assigned or ambiguous worker: {}".format(reason))
        action = make_action(env, "steer", worker=worker, request_digest=request_digest)
        lease = stack.enter_context(slot_lease(env, worker["slot"]))
        claim_pending(env, state, action)
      mutation = provider_mutate(env, action, lease)
      with controller_lock(env):
        apply_pending(env, action, mutation)
    print("steer request digest delivered to the exact worker generation")


def message_lane_worker(env, args, command):
    """Resolve the exact assigned worker for one message-lane command.

    Read-only on purpose: the state is loaded under the fleet lock, checked
    with command_execute's own identity gates (assigned status, exact
    assignment generation, no release proof), and never saved - neither
    message op modifies controller.json or any other lifecycle state.

    Role scope: until PR 4's spawn lane creates compartments, no secondmate
    worker exists to address, so the lane deliberately serves author-role
    workers as well as secondmate compartments; PR 4/6 narrows the callers
    to compartments.
    """
    with controller_lock(env):
        state = load_state(env)
        key = request_key(require_id("task", args.task), require_id("task generation", args.task_generation))
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError("{} requires one exact assigned task generation".format(command))
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("{} assignment generation is not exact".format(command))
        if worker.get("release_proof") is not None:
            raise LifecycleError("released work cannot use the compartment message lane")
        return {
            "slot": worker["slot"],
            "role": worker.get("role", "author"),
            "cloud_generation": worker["cloud_generation"],
            "bindings": worker["bindings"],
        }


def command_message_put(env, args):
    if (args.file is None) == (args.attach is None):
        raise LifecycleError("message-put requires exactly one of --file or --attach")
    source = Path(args.file if args.file is not None else args.attach)
    if source.is_symlink() or not source.is_file():
        raise LifecycleError("message payload file is unavailable: {}".format(source))
    message = message_lane_worker(env, args, "message-put")
    message.update({
        "lane": "json" if args.file is not None else "attach",
        "file": str(source.resolve()),
        "message_bytes": source.stat().st_size,
    })
    # THE ONE DELIBERATE CLAIM-EXEMPT CARVE (design R2/R3 B.1/B.9, and the
    # doc sentence next to the claim contract in docs/azure-workers.md): no
    # make_action, no claim_pending, no apply_pending, no slot_lease. A leg's
    # execute claim occupies pending_actions[slot] for its whole wall and
    # claim_pending refuses any different key on that slot, so a claimed
    # message lane could never deliver during a leg - precisely when delivery
    # matters. Safe only because the provider op is a bounded,
    # content-addressed, idempotent data-plane blob write that touches no
    # compute, no money, and no lifecycle state; idempotency comes from the
    # content address, which is stronger than a claim for this payload class.
    result = provider_call(env, "message-put", message)["result"]
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def command_message_collect(env, args):
    output_dir = Path(args.output_dir)
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise LifecycleError("message collect output directory is unavailable: {}".format(args.output_dir))
    message = message_lane_worker(env, args, "message-collect")
    message.update({
        "output_dir": str(output_dir.resolve()),
        # The provider caps each call's downloads at its transfer budget,
        # which equals this constant, so the subprocess deadline is sized
        # from the bytes one call can actually fetch; already-collected
        # history is skipped without a transfer and costs nothing here.
        "message_bytes": MESSAGE_ATTACH_MAX_BYTES,
    })
    if args.after is not None:
        message["after"] = args.after
    # Same claim-exempt carve as message-put: read-only dumb transport,
    # shaped like inventory. Chain verification belongs to the secondmate
    # monitor, never here, and the provider op refuses divergent overwrites
    # of existing local files rather than deciding anything.
    result = provider_call(env, "message-collect", message)["result"]
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


def command_compartment_chain_tip(env, args):
    """Record one compartment's verified outbox chain tip on its WORKER RECORD.

    This exists because a hash chain proves nothing without a trustworthy
    anchor. The compartment outbox is anchored at one end by a public genesis
    constant and at the other by its verified tip; when the authority read that
    tip out of state/<task>.cloud-secondmate-state.json, it was reading the
    same attacker-writable file, in the same directory as the mailbox, that it
    was trying to check. An attacker could recompute SHA-256 exactly as the
    monitor does and write a matching tip, so a wholly fabricated chain
    verified. The monitor's own tip check is sound because the monitor is the
    live writer comparing against its own prior state; for the authority, which
    by its own endpoint receipt runs only after the monitor is dead and the
    file is unowned, that check was vacuous.

    So the tip belongs where blocker 1's role fix put evidence provenance: the
    controller document, fenced, lock-guarded, written only through this CLI.

    Deliberately NOT part of the message lane. PR 3's invariant is that
    message-put/message-collect touch no lifecycle state, and a static test
    pins that neither rewrites controller.json; recording the tip inside
    message-collect would trade one hole for another. This is its own command:
    claim-exempt (it touches no compute, no money, and no provider), but it is
    a lifecycle write, not a data-plane transfer.

    Monotonic by construction: the sequence may only advance, and a replay of
    the same sequence must carry the same digest. A lower sequence, or the same
    sequence with a different digest, is a fork or a rewind and refuses.
    """
    require_id("task", args.task)
    require_id("task generation", args.task_generation)
    sequence = args.sequence
    if isinstance(sequence, bool) or not isinstance(sequence, int) or sequence < 1:
        raise LifecycleError("compartment chain tip sequence must be a positive integer")
    chain_digest = require_binding("compartment chain tip digest", args.chain_digest)
    with controller_lock(env):
        state = load_state(env)
        key = request_key(args.task, args.task_generation)
        item = state["queue"].get(key)
        if item is None or item.get("status") != "assigned":
            raise LifecycleError(
                "compartment chain tip requires one exact assigned task generation")
        if item.get("role") != "secondmate":
            raise LifecycleError("compartment chain tip is owned by secondmate compartments only")
        worker = state["workers"].get(str(item.get("slot")))
        if worker is None or worker.get("queue_key") != key:
            raise LifecycleError("compartment chain tip task has no exact durable worker owner")
        if worker.get("assignment_generation") != args.assignment_generation:
            raise LifecycleError("compartment chain tip assignment generation is not exact")
        if worker.get("release_proof") is not None:
            raise LifecycleError("released work cannot record a compartment chain tip")
        current = worker.get("verified_chain_tip")
        if isinstance(current, dict):
            held = current.get("sequence")
            if isinstance(held, int) and not isinstance(held, bool):
                if sequence < held:
                    raise LifecycleError(
                        "compartment chain tip refuses to rewind from sequence {} to {}".format(
                            held, sequence))
                if sequence == held and current.get("chain_digest") != chain_digest:
                    raise LifecycleError(
                        "compartment chain tip sequence {} already recorded a different digest".format(
                            sequence))
        worker["verified_chain_tip"] = {
            "sequence": sequence,
            "chain_digest": chain_digest,
            "recorded_at": iso_utc(),
        }
        save_state(env, state)
    print("recorded compartment chain tip {} for {}".format(sequence, args.task))


def command_status(env, args):
    inventory = None
    if args.live:
        inventory = provider_call(env, "inventory")["inventory"]
    with controller_lock(env):
        state = load_state(env)
        if inventory is not None:
            state["last_metrics"] = metrics_from_inventory(inventory)
            roll_daily_baseline(state, inventory["metrics"].get("actual_usd"))
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
    elif args.command == "capacity-retire-fence":
        command_capacity_retire_fence(env, args)
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
    elif args.command == "service-complete":
        command_service_complete(env, args)
    elif args.command == "withdraw":
        command_withdraw(env, args)
    elif args.command == "surrender":
        command_surrender(env, args)
    elif args.command == "abandon-claim":
        command_abandon_claim(env, args)
    elif args.command == "resume":
        command_resume(env, args)
    elif args.command == "steer":
        command_steer(env, args)
    elif args.command == "message-put":
        command_message_put(env, args)
    elif args.command == "message-collect":
        command_message_collect(env, args)
    elif args.command == "compartment-chain-tip":
        command_compartment_chain_tip(env, args)
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
