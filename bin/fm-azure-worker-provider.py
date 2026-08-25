#!/usr/bin/env python3
"""Azure adapter for the provider-neutral elastic worker lifecycle.

The adapter accepts one bounded JSON request on stdin and prints one JSON
response. It never adopts names outside the reviewed resource group and never
mutates a resource until complete owner, generation, task, cloud-instance,
disk, account, and worktree identity matches the controller action.

The compartment message lane (message-put/message-collect) is claim-exempt
data-plane transport with one delivery-fencing contract PR 4 must implement:
a slot-addressed transfer runs outside the controller lock, so a late message
can land in a recreated slot's container; the secondmate monitor therefore
stamps assignment_generation inside every message envelope and the session
runner refuses envelopes naming a foreign generation. The runner half is
DEFERRED: the runner's closed inbox schema cannot carry the field yet, so
the generation rides inside the envelope nonce and only the controller's
exact-assignment gate enforces it today.
"""

import base64
import contextlib
import datetime as dt
import email.utils
import io
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request


ROOT = Path(__file__).resolve().parent.parent
PILOT = ROOT / "bin" / "fm-azure-pilot.sh"
LANDED_FILES = (
    "bin/fm-azure-worker-provider.py",
    "bin/fm-worker-lifecycle.py",
    "bin/fm-worker-lifecycle.sh",
    "bin/fm-worker-supervisor.py",
    "bin/fm-azure-runner.py",
    "bin/fm-azure-pilot.sh",
    "docs/azure-pilot/main.json",
    "docs/azure-runner.md",
    "docs/azure-workers.md",
)
REQUEST_SCHEMA = "fm.worker-provider-request/v1"
RESPONSE_SCHEMA = "fm.worker-provider-response/v1"
INVENTORY_SCHEMA = "fm.worker-provider-inventory/v1"
EXECUTION_TERMINAL_SCHEMA = "fm.worker-execution-terminal/v1"
EXECUTION_RESULT_SCHEMA = "fm.worker-execution-result/v1"
EXECUTE_DISPOSITION_SUBMIT = "submit"
EXECUTE_DISPOSITION_TERMINAL = "terminal"
EXECUTE_DISPOSITION_RECOVERED = "recovered"
EXECUTION_REQUEST_TAG = "execution-request-digest"
EXECUTION_IDEMPOTENCY_TAG = "execution-idempotency-key"
MAX_INPUT_BYTES = 2 * 1024 * 1024
# The one blob name the guest may create, and the ceiling the supervisor
# enforces before it uploads; both sides bound the same transfer. The name
# carries the request digest so a later execute against the same worker
# cannot overwrite an outcome the controller has not collected yet.
OUTCOME_BLOB_PREFIX = "outcome-"
# Must equal MAX_OUTCOME_BYTES in bin/fm-worker-supervisor.py. The supervisor
# is a standalone pinned file that cannot import from the repository, so the
# two literals are kept in step by a test rather than by runtime coupling.
MAX_OUTCOME_BYTES = 256 * 1024 * 1024
# The compartment message lane (message-put/message-collect) is the ONE
# provider operation family outside the per-slot claim contract: bounded,
# content-addressed, idempotent data-plane blob transfers that touch no
# compute, no money, and no lifecycle state. docs/azure-workers.md names the
# carve next to the claim contract; require_session_blob_name enforces its
# namespace boundary where it is used. MESSAGE_ATTACH_MAX_BYTES must equal the
# controller's constant of the same name (kept in step by a test).
MESSAGE_JSON_MAX_BYTES = 256 * 1024
MESSAGE_ATTACH_MAX_BYTES = 256 * 1024 * 1024
SESSION_BLOB_PREFIX = "session/"
MESSAGE_INBOX_PREFIX = "session/in/"
MESSAGE_ATTACH_PREFIX = "session/in/attach/"
MESSAGE_OUTBOX_PREFIX = "session/out/"
# Collect is a bounded incremental walk, never a hard refusal on mailbox
# depth: at most MAX_BLOBS names per az listing page, at most MAX_PAGES pages
# walked per call while skipping already-collected history, at most
# PAGE_BLOBS entries processed per call, and at most the transfer budget
# downloaded per call. The budget equals the per-blob attach ceiling, so one
# maximum-size blob always fits in one call and the controller can size the
# subprocess deadline from the same number the fetch loop is bounded by.
# Anything beyond a bound is reported through the cursor and the more flag,
# collectable by the next call.
MESSAGE_COLLECT_MAX_BLOBS = 4096
MESSAGE_COLLECT_PAGE_BLOBS = 512
MESSAGE_COLLECT_MAX_PAGES = 16
MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES = MESSAGE_ATTACH_MAX_BYTES
MESSAGE_LOCAL_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
# Staging (archive fetches plus the repository clone) runs BEFORE the wall
# starts and collection runs after it ends, so a bound covering a whole guest
# run is wall plus this, never wall alone. The GUEST gives up first and the
# client waiting on it gets the extra margin, so a guest timeout is reported
# rather than raced.
#
# The floor is the supervisor's OWN worst case outside the wall, summed from
# its per-step timeouts: payload fetch 300 + account fetch 300 + clone 600 +
# rev-parse 60 + rev-list 120 + status 120 + bundle 600 + upload 600 = 2700.
# Undershooting it is not a slow failure, it is a DESTRUCTIVE one: an Azure
# kill is not an exception the supervisor can catch, so no executed marker is
# written, and the next dispatch re-runs the command and rmtrees the staged
# repository, deleting the commits the killed run had already made.
# tests/fm-azure-pilot.test.sh derives this floor from the supervisor source so
# it cannot rot back under the budget.
GUEST_RUN_SLACK_SECONDS = 3000
CLIENT_WAIT_SLACK_SECONDS = 3600
AZ_TIMEOUT_SECONDS = 300
# The bootstrap run command blocks on the guest too. Its work is bounded and
# much smaller than a task: a per-disk device wait (60s each), mkfs and the
# mounts, plus the supervisor install. Same nesting rule as the execute path,
# the guest gives up first so its timeout is what gets reported.
BOOTSTRAP_GUEST_TIMEOUT_SECONDS = 1800
BOOTSTRAP_CLIENT_TIMEOUT_SECONDS = 2400

# What the provider spends AROUND the blocking guest call, each step at its own
# bound. The controller supervises the WHOLE subprocess, so its bound has to
# cover the client wait plus both of these; covering only the client wait kills
# the provider during collection and the task runs a second time. These are
# named here, next to the bounds they are made of, so bin/fm-worker-lifecycle.py
# cannot drift away from them unnoticed: tests/fm-azure-pilot.test.sh checks the
# controller bound against these exact values.
PRE_GUEST_CALL_BUDGET_SECONDS = (
    AZ_TIMEOUT_SECONDS        # opening inventory sweep
    + AZ_TIMEOUT_SECONDS      # payload archive upload
    + AZ_TIMEOUT_SECONDS      # account archive upload
    + AZ_TIMEOUT_SECONDS      # request blob upload and SAS mints
)
POST_GUEST_CALL_BUDGET_SECONDS = (
    AZ_TIMEOUT_SECONDS                                          # instance-view read
    + AZ_TIMEOUT_SECONDS                                        # outcome size probe
    + AZ_TIMEOUT_SECONDS + MAX_OUTCOME_BYTES // (256 * 1024)    # bounded download at its ceiling
    + AZ_TIMEOUT_SECONDS                                        # staging-result upload
    + AZ_TIMEOUT_SECONDS                                        # closing inventory sweep
)
# A create does not block on a task, but it does run a long ARM deployment and
# the blocking bootstrap, plus the lifecycle children and two tag-convergence
# sweeps. Same rule: the controller bound must cover all of it.
# A steer also blocks on the guest. RunShellScript is an unmanaged run command
# and takes no --timeout-in-seconds, so the client bound is the only one there
# is, and leaving it at the ordinary control-plane default is the same shape
# called broken for bootstrap and execute above.
# Starting a stopped VM is an ARM power operation measured in minutes, not the
# seconds an ordinary control-plane call takes.
VM_START_TIMEOUT_SECONDS = 900
# How long to wait between power-state reads while an ARM power transition is
# in flight. The TTL schedule fires daily, so a create racing a deallocate is
# ordinary, not exotic.
VM_POWER_POLL_SECONDS = 10
# Bound the READS as well as the wall clock. A deadline alone means a gate that
# never settles spins until the deadline: a slow failure, and an unpredictable
# one, since how long it takes depends on how fast Azure answers. A read count
# fails the same way every time.
VM_POWER_MAX_READS = 90
STEER_CLIENT_TIMEOUT_SECONDS = 600
# The steer is bracketed by two full inventory sweeps.
STEER_BUDGET_SECONDS = STEER_CLIENT_TIMEOUT_SECONDS + AZ_TIMEOUT_SECONDS * 2
PILOT_CREATE_DEPLOY_TIMEOUT_SECONDS = 3600
CREATE_LIFECYCLE_BUDGET_SECONDS = (
    BOOTSTRAP_CLIENT_TIMEOUT_SECONDS
    + VM_START_TIMEOUT_SECONDS   # a converged worker is often stopped by its TTL
    + AZ_TIMEOUT_SECONDS * 16    # instance view, task stub, TTL, blob uploads, sweeps, tagging
)
RESOURCE_API = {
    "vm": "2024-03-01",
    "nic": "2023-09-01",
    "os-disk": "2023-10-02",
    "task-disk": "2023-10-02",
    "account-disk": "2023-10-02",
    "identity": "2023-01-31",
    "role-assignment": "2022-04-01",
    "monitor-extension": "2024-03-01",
    "bootstrap-command": "2024-03-01",
    "task-command": "2024-03-01",
    "ttl-schedule": "2018-09-15",
}
SPECIALIZED_ROLES = {
    "validation-shard", "validation-cell", "policy-review", "browser-tool",
    "networkless-verifier", "crosscheck-tool",
}
SAFE_INVOCATION = re.compile(r"^azr-[0-9a-f]{12}(?:-a(?:[2-9]|[1-9][0-9]+))?$")
RUNNER_COMMISSIONING_SKU_POOL = (
    "Standard_D4as_v7",
    "Standard_D4as_v6",
    "Standard_D4s_v6",
    "Standard_D4ads_v7",
    "Standard_D4ads_v6",
    "Standard_E4as_v7",
    "Standard_E4as_v6",
    "Standard_D4ds_v6",
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
SKU_VCPUS = {sku: 4 for sku in REVIEWED_SKU_FAMILY}
SKU_VCPUS.update({sku: 8 for sku in REVIEWED_CONTROL_SKU_FAMILY})
SKU_VCPUS["Standard_D2as_v6"] = 2
REVIEWED_SPECIALIZED_SKU_FAMILY = dict(REVIEWED_SKU_FAMILY)
REVIEWED_SPECIALIZED_SKU_FAMILY.update(REVIEWED_CONTROL_SKU_FAMILY)
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
REQUIRED_RESOURCE_KINDS = (
    "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
    "role-assignment", "state-container", "monitor-extension", "bootstrap-command",
    "task-command", "ttl-schedule", "global-reservation", "staging-request",
    "staging-result",
)
MUTABLE_PROVISIONING_CHILD_KINDS = frozenset({
    "monitor-extension", "bootstrap-command", "task-command", "ttl-schedule",
})
READY_CHILD_KINDS = frozenset({"monitor-extension", "bootstrap-command"})


class ProviderError(RuntimeError):
    pass


class ProviderIdentityRefusal(ProviderError):
    pass


def canonical_bytes(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def iso_utc():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def run(command, check=True, input_bytes=None, timeout=AZ_TIMEOUT_SECONDS, env=None):
    try:
        result = subprocess.run(
            command, input=input_bytes, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout, env=env,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ProviderError("bounded command failed or timed out: {}".format(exc))
    if check and result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1000:]
        raise ProviderError("command failed ({}): {}{}".format(
            result.returncode, command[0], ": " + detail if detail else ""
        ))
    return result


def require_landed_code():
    for relative in LANDED_FILES:
        tracked = run(["git", "-C", str(ROOT), "cat-file", "-e", "HEAD:" + relative], check=False)
        unchanged = run(["git", "-C", str(ROOT), "diff", "--quiet", "HEAD", "--", relative], check=False)
        if tracked.returncode != 0 or unchanged.returncode != 0:
            raise ProviderError("Azure worker mutation requires exact committed tracked lifecycle code")
    default_ref = run([
        "git", "-C", str(ROOT), "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD",
    ], check=False)
    if default_ref.returncode != 0:
        raise ProviderError("origin default branch is unavailable for landed-code proof")
    default_name = default_ref.stdout.decode("utf-8", errors="replace").strip()
    ancestry = run([
        "git", "-C", str(ROOT), "merge-base", "--is-ancestor", "HEAD", default_name,
    ], check=False)
    if ancestry.returncode != 0:
        raise ProviderError("Azure worker mutation is allowed only from code landed on origin's default branch")


def az(controller, args, check=True, timeout=AZ_TIMEOUT_SECONDS):
    command = ["az"] + list(args) + [
        "--subscription", controller["subscription"], "--only-show-errors",
    ]
    if "--output" not in command and "-o" not in command:
        command += ["--output", "json"]
    result = run(command, check=check, timeout=timeout)
    stderr = result.stderr.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        return None, result.returncode, stderr
    try:
        return json.loads(result.stdout.decode("utf-8") or "null"), 0, stderr
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProviderError("Azure CLI returned malformed JSON: {}".format(exc))


def exact_id(controller, provider, resource_type, name):
    return "/subscriptions/{}/resourceGroups/{}/providers/{}/{}/{}".format(
        controller["subscription"], controller["resource_group"], provider, resource_type, name
    )


def expected_names(controller, slot):
    token = "{:02d}".format(slot)
    prefix = controller["prefix"]
    return {
        "vm": "vm-{}-wkr-{}".format(prefix, token),
        "nic": "nic-{}-wkr-{}".format(prefix, token),
        "os-disk": "disk-{}-wkr-{}-os".format(prefix, token),
        "task-disk": "disk-{}-wkr-{}-task".format(prefix, token),
        "account-disk": "disk-{}-wkr-{}-account".format(prefix, token),
        "identity": "id-{}-wkr-{}".format(prefix, token),
        "state-container": "worker-state-{}".format(token),
        "monitor-extension": "AzureMonitorLinuxAgent",
        "bootstrap-command": "bootstrap",
        "task-command": "execute",
        "ttl-schedule": "shutdown-computevm-vm-{}-wkr-{}".format(prefix, token),
        "global-reservation": "reservation.json",
        "staging-request": "request.json",
        "staging-result": "result.json",
    }


def action_tags(controller, action):
    bindings = action["bindings"]
    if action.get("role") == "secondmate":
        # The controller's expected_tags branches identically; a compartment
        # VM must never carry the one-task crewmate posture in the cloud's own
        # metadata.
        return {
            "workload": "firstmate",
            "firstmate-role": "secondmate-compartment",
            "deployment-generation": controller["deployment_generation"],
            "cleanup-owner": controller["owner"],
            "worker-slot": str(action["slot"]),
            "home-binding": bindings["home_binding"],
            "task-binding": bindings["task"],
            "task-generation": bindings["task_generation"],
            "assignment-generation": bindings["assignment_generation"],
            "cloud-generation": str(action["cloud_generation"]),
            "account-binding": bindings["account_binding"],
            "worktree-binding": bindings["worktree_binding"],
            "repository-binding": bindings["repository_binding"],
            "repository-generation": bindings["repository_generation"],
            "agent-capacity": "one-home-scoped-secondmate",
            "nested-team": "forbidden",
            "child-launcher": "absent",
            "browser-profile": "forbidden",
            "lifecycle": "disposable-compute-retained-data",
        }
    return {
        "workload": "firstmate",
        "firstmate-role": "worker",
        "deployment-generation": controller["deployment_generation"],
        "cleanup-owner": controller["owner"],
        "worker-slot": str(action["slot"]),
        "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"],
        "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "cloud-generation": str(action["cloud_generation"]),
        "account-binding": bindings["account_binding"],
        "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "agent-capacity": "one-task-scoped-crewmate",
        "nested-team": "forbidden",
        "secondmate-placement": "forbidden",
        "browser-profile": "forbidden",
        "lifecycle": "disposable-compute-retained-data",
    }


def metadata_to_tags(metadata):
    tags = {}
    for key, value in (metadata or {}).items():
        tags[key.replace("_", "-")] = value
    return tags


def tags_to_metadata(tags):
    return {key.replace("-", "_"): str(value) for key, value in tags.items()}


def immutable_id(kind, value):
    properties = value.get("properties", value)
    if kind == "vm":
        return properties.get("vmId") or value.get("vmId")
    if kind == "nic":
        return properties.get("resourceGuid") or value.get("resourceGuid")
    if kind in ("os-disk", "task-disk", "account-disk"):
        return properties.get("uniqueId") or value.get("uniqueId")
    if kind == "identity":
        return properties.get("principalId") or value.get("principalId")
    if kind == "role-assignment":
        principal = value.get("principalId") or properties.get("principalId")
        role = value.get("roleDefinitionId") or properties.get("roleDefinitionId")
        return "{}|{}".format(principal, role) if principal and role else None
    if kind == "state-container":
        return value.get("etag") or properties.get("etag") or value.get("version")
    if kind in MUTABLE_PROVISIONING_CHILD_KINDS:
        # Azure mutates provisioningState during ordinary VM lifecycle
        # transitions (including Succeeded -> Updating after deallocation).
        # The child ARM ID is stable; attachment, tags, and readiness are
        # validated independently by recorded_exact.
        return value.get("id")
    if kind in ("global-reservation", "staging-request", "staging-result"):
        return value.get("etag") or properties.get("etag") or value.get("version")
    return None


def resource_record(kind, value, power_state=None, tags_override=None):
    resource_id = value.get("id")
    identity = immutable_id(kind, value)
    if not resource_id or not identity:
        raise ProviderError("{} immutable identity is incomplete".format(kind))
    record = {
        "id": resource_id,
        "immutable_id": identity,
        # Storage listings carry the ETag under properties (the top level has
        # none), so both locations feed the conditional-delete guard.
        "etag": value.get("etag") or (value.get("properties") or {}).get("etag"),
        "tags": dict(tags_override if tags_override is not None else (value.get("tags") or {})),
    }
    if power_state is not None:
        record["power_state"] = power_state
    properties = value.get("properties", value)
    if kind == "nic":
        record["attached_to"] = (properties.get("virtualMachine") or {}).get("id")
        configs = properties.get("ipConfigurations") or value.get("ipConfigurations") or []
        for config in configs:
            config_properties = config.get("properties", config)
            if config_properties.get("publicIPAddress") or config_properties.get("publicIpAddress"):
                raise ProviderError("worker NIC has a public IP relation")
    if kind in ("os-disk", "task-disk", "account-disk"):
        record["attached_to"] = value.get("managedBy") or properties.get("managedBy")
    if kind == "state-container":
        record["last_modified"] = properties.get("lastModified") or value.get("lastModified")
    if kind in ("monitor-extension", "bootstrap-command", "task-command"):
        record["attached_to"] = properties.get("virtualMachineId") or value.get("attached_to")
        record["provisioning_state"] = properties.get("provisioningState") or value.get("provisioningState")
    if kind == "ttl-schedule":
        record["attached_to"] = properties.get("targetResourceId") or value.get("attached_to")
        record["status"] = properties.get("status") or value.get("status")
        record["deadline"] = properties.get("dailyRecurrence", {}).get("time") or value.get("deadline")
    if kind in ("global-reservation", "staging-request", "staging-result"):
        record["digest"] = properties.get("contentDigest") or value.get("digest")
        record["length"] = properties.get("contentLength") or value.get("length")
    return record


def show_full(controller, resource_id, api_version=None):
    args = ["resource", "show", "--ids", resource_id]
    if api_version:
        args += ["--api-version", api_version]
    value, rc, stderr = az(controller, args, check=False)
    if rc != 0 or not isinstance(value, dict):
        raise ProviderError("Azure child inventory read failed or was malformed: {}".format(stderr))
    return value


def list_json(controller, args):
    value, rc, stderr = az(controller, args, check=False)
    if rc != 0 or not isinstance(value, list):
        raise ProviderError("Azure inventory call failed or was malformed: {}".format(stderr))
    return value


def blob_record(controller, storage, container, name, kind, required=False):
    value, rc, stderr = az(controller, [
        "storage", "blob", "show", "--auth-mode", "login", "--account-name", storage,
        "--container-name", container, "--name", name,
    ], check=False)
    if rc != 0:
        if required:
            raise ProviderError("exact {} blob is unreadable or absent: {}".format(kind, stderr))
        return None
    properties = value.get("properties", value) if isinstance(value, dict) else {}
    metadata = metadata_to_tags((value or {}).get("metadata") or properties.get("metadata") or {})
    digest = metadata.get("content-digest") or properties.get("contentDigest")
    length = properties.get("contentLength")
    if length is None:
        length = (value or {}).get("contentLength")
    etag = (value or {}).get("etag") or properties.get("etag")
    if not etag or not re.fullmatch(r"[0-9a-f]{64}", str(digest or "")):
        raise ProviderError("exact {} blob identity is incomplete".format(kind))
    blob_id = (
        exact_id(controller, "Microsoft.Storage", "storageAccounts", storage)
        + "/blobServices/default/containers/{}/blobs/{}".format(container, name)
    )
    return resource_record(kind, {
        "id": blob_id, "etag": etag, "metadata": metadata,
        "properties": {"etag": etag, "contentDigest": digest, "contentLength": length},
    }, tags_override=metadata)


def is_exact_fleet(controller, tags):
    return (
        tags.get("workload") == "firstmate"
        and tags.get("deployment-generation") == controller["deployment_generation"]
        and tags.get("cleanup-owner") == controller["owner"]
    )


def slot_from_name(name, pattern):
    match = re.match(pattern + r"([0-9]{2})(?:[-/]|$)", str(name))
    if not match:
        return None
    slot = int(match.group(1))
    return slot if 1 <= slot <= 16 else None


def slot_sibling_tags(workers, slot):
    # Children are only tagged at convergence, so a create interrupted before
    # that point leaves untagged resources next to exact-fleet template
    # siblings. Emptiness inherits a same-slot sibling's tags (VM first); a
    # slot with no proven sibling yields emptiness and still classifies as
    # foreign. Non-empty foreign tags never reach this inheritance.
    if slot not in workers:
        return {}
    resources = workers[slot]["resources"]
    donor = resources.get("vm") or next(iter(resources.values()), None)
    return dict((donor or {}).get("tags") or {})


def partial_container_metadata(metadata, slot, workers):
    return metadata if metadata else slot_sibling_tags(workers, slot)


def cost_body(controller, forecast):
    today = dt.datetime.now(dt.timezone.utc).date()
    month_start = today.replace(day=1)
    if month_start.month == 12:
        month_end = month_start.replace(year=month_start.year + 1, month=1)
    else:
        month_end = month_start.replace(month=month_start.month + 1)
    body = {
        "type": "Usage",
        "timeframe": "MonthToDate",
        "dataset": {
            "granularity": "None",
            "aggregation": {"totalCost": {"name": "PreTaxCost", "function": "Sum"}},
            "filter": {
                "dimensions": {
                    "name": "ResourceGroupName", "operator": "In",
                    "values": [controller["resource_group"]],
                }
            },
        },
    }
    if forecast:
        body["timeframe"] = "Custom"
        body["timePeriod"] = {
            "from": month_start.isoformat() + "T00:00:00Z",
            "to": month_end.isoformat() + "T00:00:00Z",
        }
    return body


def cost_query(controller, forecast):
    value, _untrained = cost_query_with_state(controller, forecast)
    return value


COST_THROTTLE_RETRY_DEADLINE_SECONDS = 180
COST_THROTTLE_RETRY_SPACING_SECONDS = 15


def cost_throttle_signature(stderr):
    # Cost Management throttles the az CLI's shared client-type request
    # bucket with a retry-after of a few seconds even while the per-hour
    # query budget is nearly untouched, so a bounded short-spaced retry
    # is the correct remedy; a long quiet window is not.
    text = str(stderr)
    return '"code":"429"' in text or "Too Many Requests" in text


COST_CACHE_FRESH_SECONDS = 600
COST_CACHE_MAX_AGE_SECONDS = 4 * 60 * 60
RETAIL_RATE_CACHE_FRESH_SECONDS = 7 * 24 * 3600


def shared_runner_state_dir():
    home = os.environ.get("FM_HOME", "")
    if not home:
        return None
    path = Path(home) / "state" / "azure-runner"
    return path if path.is_dir() else None


def cost_cache_key(endpoint, url, body):
    body_digest = "sha256:" + hashlib.sha256(
        json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    ).hexdigest()
    key = hashlib.sha256((endpoint + "\0" + url + "\0" + body_digest).encode("utf-8")).hexdigest()
    return key, body_digest


def cost_result_value(result):
    properties = result.get("properties", result)
    columns = properties.get("columns") or []
    rows = properties.get("rows") or []
    if not rows:
        return 0.0
    names = [item.get("name") for item in columns]
    index = names.index("PreTaxCost") if "PreTaxCost" in names else 0
    try:
        return float(rows[0][index])
    except (IndexError, TypeError, ValueError):
        return None


def load_cost_cache_entry(controller, key, endpoint, body_digest, max_age_seconds):
    state_dir = shared_runner_state_dir()
    if state_dir is None:
        return None
    try:
        cache = json.loads((state_dir / "cost-management-cache.json").read_text(encoding="utf-8"))
        entry = cache["entries"][key]
        fetched = dt.datetime.fromisoformat(entry["fetched_at"].replace("Z", "+00:00"))
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None
    if (
        cache.get("schema") != "fm.azure-cost-cache/v1"
        or cache.get("subscription") != controller["subscription"]
        or cache.get("resource_group") != controller["resource_group"]
        or entry.get("endpoint") != endpoint
        or entry.get("body_digest") != body_digest
        or fetched.tzinfo is None
    ):
        return None
    now = dt.datetime.now(dt.timezone.utc)
    if now < fetched or (now - fetched).total_seconds() > max_age_seconds:
        return None
    return entry.get("result") if isinstance(entry.get("result"), dict) else None


def save_cost_cache_entry(controller, key, endpoint, body_digest, result):
    state_dir = shared_runner_state_dir()
    if state_dir is None:
        return
    path = state_dir / "cost-management-cache.json"
    try:
        with open(state_dir / ".lock", "a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                cache = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                cache = {
                    "schema": "fm.azure-cost-cache/v1",
                    "subscription": controller["subscription"],
                    "resource_group": controller["resource_group"],
                    "entries": {},
                }
            if (
                cache.get("schema") != "fm.azure-cost-cache/v1"
                or cache.get("subscription") != controller["subscription"]
                or cache.get("resource_group") != controller["resource_group"]
                or not isinstance(cache.get("entries"), dict)
            ):
                return
            cache["entries"][key] = {
                "endpoint": endpoint,
                "body_digest": body_digest,
                "server_date": email.utils.formatdate(usegmt=True),
                "fetched_at": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                "result": result,
            }
            temp = path.with_name(".{}.{}.tmp".format(path.name, os.getpid()))
            temp.write_text(json.dumps(cache, sort_keys=True, separators=(",", ":")) + "\n", encoding="utf-8")
            os.chmod(temp, 0o600)
            os.replace(temp, path)
    except OSError:
        return


def cost_query_with_state(controller, forecast):
    """Return (value, untrained). untrained is True only for the exact
    Cost Management refusal that the forecast model has insufficient
    training data, which is the expected bootstrap state of a fresh
    resource group; every other failure stays plainly unreadable.

    Spend reads go through the shared runner cost cache: a fresh entry
    skips the API entirely, so concurrent shard admissions stop competing
    for the shared Cost Management throttle bucket (generation 050 lost a
    full shard fan-out to admission refusals from that competition). On an
    unreadable live read a bounded-age stale entry substitutes: admission
    adds outstanding durable reservations on top of this figure, so spend
    landed between refreshes cannot bypass the budget ceiling through
    staleness."""
    endpoint = "forecast" if forecast else "query"
    url = "https://management.azure.com/subscriptions/{}/providers/Microsoft.CostManagement/{}?api-version=2023-11-01".format(
        controller["subscription"], endpoint
    )
    body = cost_body(controller, forecast)
    key, body_digest = cost_cache_key(endpoint, url, body)
    fresh = load_cost_cache_entry(controller, key, endpoint, body_digest, COST_CACHE_FRESH_SECONDS)
    if fresh is not None:
        value = cost_result_value(fresh)
        if value is not None:
            return value, False
    fd, name = tempfile.mkstemp(prefix="fm-worker-cost-", suffix=".json")
    os.chmod(name, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(body, handle, separators=(",", ":"))
        deadline = time.monotonic() + COST_THROTTLE_RETRY_DEADLINE_SECONDS
        while True:
            result, rc, stderr = az(controller, [
                "rest", "--method", "post", "--url", url, "--body", "@" + name,
            ], check=False)
            if rc == 0 and isinstance(result, dict):
                break
            untrained = bool(forecast) and "cost training data" in str(stderr).lower()
            if untrained:
                return None, True
            if (
                cost_throttle_signature(stderr)
                and time.monotonic() + COST_THROTTLE_RETRY_SPACING_SECONDS <= deadline
            ):
                time.sleep(COST_THROTTLE_RETRY_SPACING_SECONDS)
                continue
            stale = load_cost_cache_entry(controller, key, endpoint, body_digest, COST_CACHE_MAX_AGE_SECONDS)
            if stale is not None:
                value = cost_result_value(stale)
                if value is not None:
                    return value, False
            return None, False
        value = cost_result_value(result)
        if value is None:
            return None, False
        save_cost_cache_entry(controller, key, endpoint, body_digest, result)
        return value, False
    except (IndexError, TypeError, ValueError):
        return None, False
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(name).unlink()


def retail_rate(sku):
    """Resolve the SKU's hourly retail rate through the shared runner cache.

    The rate only feeds worst-case cost ceilings, so freshness is worth very
    little and prices.azure.com throttles bursts hard. A fresh cached rate
    skips the API entirely; a live failure falls back to any cached rate
    verbatim. Only a SKU with no cached rate requires the live read."""
    state_dir = shared_runner_state_dir()
    cache_path = None if state_dir is None else state_dir / "retail-rate-cache.json"
    cache = {}
    if cache_path is not None:
        try:
            cache = json.loads(cache_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cache = {}
    entry = cache.get(sku)
    cached_rate = None
    if (
        isinstance(entry, dict)
        and isinstance(entry.get("rate"), (int, float))
        and entry["rate"] > 0
        and isinstance(entry.get("fetched_at"), (int, float))
    ):
        cached_rate = float(entry["rate"])
        if time.time() - entry["fetched_at"] < RETAIL_RATE_CACHE_FRESH_SECONDS:
            return cached_rate
    rate = retail_rate_live(sku)
    if rate is None:
        return cached_rate
    if cache_path is not None:
        try:
            cache[sku] = {"rate": rate, "fetched_at": time.time()}
            temp = cache_path.with_suffix(".tmp")
            temp.write_text(json.dumps(cache, sort_keys=True) + "\n", encoding="utf-8")
            os.chmod(temp, 0o600)
            temp.replace(cache_path)
        except OSError:
            pass
    return rate


def retail_rate_live(sku):
    query = urllib.parse.urlencode({
        "$filter": "armRegionName eq 'eastus' and armSkuName eq '{}' and priceType eq 'Consumption'".format(sku)
    })
    request = urllib.request.Request(
        "https://prices.azure.com/api/retail/prices?" + query,
        headers={"User-Agent": "firstmate-elastic-worker/1"},
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = json.load(response)
    except Exception:
        return None
    sku_shape = re.fullmatch(r"Standard_([DE])\d+([a-z]+)_v(\d+)", sku)
    if not isinstance(data, dict) or sku_shape is None:
        return None
    expected_meter = sku.removeprefix("Standard_").replace("_", " ")
    expected_product = "Virtual Machines {}{}v{} Series".format(
        sku_shape.group(1), sku_shape.group(2), sku_shape.group(3)
    )
    excluded = (
        "spot", "low priority", "low-priority", "windows", "dev/test", "dev test",
        "reservation", "savings",
    )
    prices = set()
    for item in data.get("Items", []):
        if not isinstance(item, dict):
            continue
        offer = " ".join(str(item.get(field, "")) for field in (
            "productName", "meterName", "skuName", "type", "priceType", "reservationTerm",
        )).casefold()
        if any(token in offer for token in excluded):
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
            tier = float(item["tierMinimumUnits"])
        except (KeyError, TypeError, ValueError):
            continue
        if math.isfinite(price) and price > 0 and price == unit_price and tier == 0:
            prices.add(price)
    return prices.pop() if len(prices) == 1 else None


def specialized_capacity_inventory(controller, vms, identities):
    active = {}
    active_by_family = {}
    for vm in vms:
        tags = vm.get("tags") or {}
        if tags.get("firstmate-role") not in SPECIALIZED_ROLES:
            continue
        invocation = tags.get("invocation-binding", "")
        # The permanent validation-shards controller identity shares the role
        # tag but has no invocation binding and is not disposable capacity.
        if not invocation:
            continue
        if not is_exact_fleet(controller, tags):
            raise ProviderError("specialized VM has foreign owner or deployment generation")
        sku = tags.get("selected-sku") or (vm.get("hardwareProfile") or {}).get("vmSize")
        family = tags.get("sku-family")
        if (
            not SAFE_INVOCATION.match(invocation)
            or sku not in SKU_VCPUS
            or family is None
            or family.lower() != REVIEWED_SPECIALIZED_SKU_FAMILY.get(sku, "").lower()
        ):
            raise ProviderError("specialized VM capacity identity is malformed")
        power = str(vm.get("powerState") or vm.get("power_state") or "unknown").lower()
        if "deallocated" in power:
            continue
        if invocation in active:
            raise ProviderError("specialized VM invocation is duplicated")
        active[invocation] = {"sku": sku, "sku_family": family, "vcpus": SKU_VCPUS[sku]}
        active_by_family[family] = active_by_family.get(family, 0) + SKU_VCPUS[sku]

    reservations = []
    seen = set()
    for identity in identities:
        tags = identity.get("tags") or {}
        if tags.get("firstmate-role") != "runner-cost-reservation":
            continue
        if not is_exact_fleet(controller, tags):
            raise ProviderError("runner reservation has foreign owner or deployment generation")
        invocation = tags.get("invocation-binding", "")
        sku = tags.get("selected-sku", "")
        family = tags.get("sku-family", "")
        mode = tags.get("cost-admission-mode")
        ordinal_text = tags.get("cell-ordinal", "")
        principal = (identity.get("properties") or {}).get("principalId") or identity.get("principalId")
        expected_name = "id-{}-rsv-{}".format(
            controller["prefix"], invocation.split("-")[1] if SAFE_INVOCATION.match(invocation) else "invalid"
        )
        expected_id = exact_id(
            controller, "Microsoft.ManagedIdentity", "userAssignedIdentities", expected_name
        )
        try:
            amount_microusd = int(tags.get("amount-microusd", ""))
        except (TypeError, ValueError):
            amount_microusd = 0
        exact_slot = ordinal_text == "none" and mode == "strict"
        if mode == "commissioning-bounded":
            try:
                ordinal = int(ordinal_text)
            except (TypeError, ValueError):
                ordinal = 0
            exact_slot = (
                1 <= ordinal <= 16
                and sku == RUNNER_COMMISSIONING_SKU_POOL[(ordinal - 1) // 2]
            )
        cleanup = tags.get("cleanup-verified-at", "")
        cleanup_complete = cleanup != "none"
        if cleanup_complete:
            try:
                dt.datetime.fromisoformat(cleanup.replace("Z", "+00:00"))
            except (TypeError, ValueError):
                raise ProviderError("runner reservation cleanup marker is malformed")
        if (
            not SAFE_INVOCATION.match(invocation)
            or invocation in seen
            or identity.get("location") != "eastus"
            or str(identity.get("id", "")).lower() != expected_id.lower()
            or sku not in SKU_VCPUS
            or REVIEWED_SPECIALIZED_SKU_FAMILY.get(sku, "").lower() != family.lower()
            or mode not in ("strict", "commissioning-bounded")
            or not exact_slot
            or amount_microusd <= 0
            or cleanup == ""
            or not re.fullmatch(r"[0-9a-f]{64}", tags.get("fence-digest", ""))
            or not tags.get("reserved-at")
            or not tags.get("compute-deadline")
            or not principal
            or tags.get("reservation-principal") != principal
        ):
            raise ProviderError("runner reservation capacity identity is not exact")
        seen.add(invocation)
        if cleanup_complete:
            if invocation in active:
                raise ProviderError("cleaned runner reservation still owns active compute")
            continue
        reservations.append({
            "reservation_id": invocation,
            "role": "specialized",
            "sku": sku,
            "sku_family": family,
            "vcpus": SKU_VCPUS[sku],
            "amount_usd": amount_microusd / 1_000_000,
            "active": invocation in active,
        })
    # There is deliberately NO "every active specialized VM must have a
    # reservation" refusal here. Nothing in this repo mints a
    # runner-cost-reservation identity: the role tag appears only in the loop
    # above, so the requirement could never be satisfied by any shard any lane
    # launches. Being global and fail-closed, its only real effect was to refuse
    # every WORKER operation for as long as ANOTHER lane had compute up, behind
    # an error naming reservations rather than the actual cause. Three
    # consecutive worker reconciles were refused this way during the first real
    # crewmate drive.
    #
    # What still guards this inventory, all above and all still fail-closed:
    # foreign owner or deployment generation, malformed SKU/family identity,
    # duplicate invocation bindings, and a cleaned reservation that still owns
    # active compute. What bounds SPEND is family and regional quota read from
    # `az vm list-usage`, not this ledger; active_by_family feeds status
    # telemetry only.
    return reservations, active_by_family


def metrics(controller, vms, capacity_reservations, specialized_active_by_family):
    actual_value = cost_query(controller, False)
    forecast_value, forecast_untrained = cost_query_with_state(controller, True)
    usage, rc, _ = az(controller, ["vm", "list-usage", "--location", "eastus"], check=False)
    regional_limit = None
    regional_used = None
    family_free = {}
    family_limit = {}
    family_used = {}
    wanted_families = set(REVIEWED_SKU_FAMILY.values()) | {
        reservation["sku_family"] for reservation in capacity_reservations
    }
    if rc == 0 and isinstance(usage, list):
        for item in usage:
            name = str((item.get("name") or {}).get("value", ""))
            try:
                limit = int(item.get("limit"))
                used = int(item.get("currentValue"))
            except (TypeError, ValueError):
                continue
            if name.lower() == "cores":
                regional_limit = limit
                regional_used = used
            for family in wanted_families:
                if name.lower() == family.lower():
                    family_limit[family] = limit
                    family_used[family] = used
                    family_free[family] = limit - used
    return {
        "actual_usd": actual_value,
        "forecast_usd": forecast_value,
        "forecast_untrained": forecast_untrained,
        "regional_limit_vcpus": regional_limit,
        "regional_used_vcpus": regional_used,
        "specialized_active_vcpus": sum(specialized_active_by_family.values()),
        "specialized_active_by_family": specialized_active_by_family,
        "family_limit_vcpus": family_limit,
        "family_used_vcpus": family_used,
        "family_free_vcpus": family_free,
        "sku_hourly_usd": {sku: retail_rate(sku) for sku, _ in sorted(set(SKU_PLAN.values()))},
    }


def inventory(controller, include_metrics=True):
    account, rc, stderr = az(controller, ["account", "show"], check=False)
    if rc != 0 or not isinstance(account, dict):
        raise ProviderError("Azure scope is unreadable: {}".format(stderr))
    if account.get("id", "").lower() != controller["subscription"] or account.get("state") != "Enabled":
        raise ProviderError("Azure subscription scope is not the exact enabled controller binding")

    prefix = re.escape(controller["prefix"])
    vms = list_json(controller, ["vm", "list", "--resource-group", controller["resource_group"], "--show-details"])
    nics = list_json(controller, ["network", "nic", "list", "--resource-group", controller["resource_group"]])
    disks = list_json(controller, ["disk", "list", "--resource-group", controller["resource_group"]])
    identities = list_json(controller, ["identity", "list", "--resource-group", controller["resource_group"]])
    extensions = list_json(controller, [
        "resource", "list", "--resource-group", controller["resource_group"],
        "--resource-type", "Microsoft.Compute/virtualMachines/extensions",
    ])
    run_commands = list_json(controller, [
        "resource", "list", "--resource-group", controller["resource_group"],
        "--resource-type", "Microsoft.Compute/virtualMachines/runCommands",
    ])
    schedules = list_json(controller, [
        "resource", "list", "--resource-group", controller["resource_group"],
        "--resource-type", "Microsoft.DevTestLab/schedules",
    ])
    # Scope casing varies across ARM responses, so filter client-side rather
    # than with a case-sensitive JMESPath query.
    scope_marker = "/resourcegroups/{}/".format(controller["resource_group"]).lower()
    roles = [
        role for role in list_json(controller, ["role", "assignment", "list", "--all"])
        if scope_marker in str(role.get("scope") or "").lower()
    ]
    containers = list_json(controller, [
        "storage", "container", "list", "--auth-mode", "login", "--include-metadata",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
    ])

    workers = {}
    conflicts = []

    def add(kind, value, slot, power=None, tags_override=None):
        tags = dict(tags_override if tags_override is not None else (value.get("tags") or {}))
        if not tags:
            tags = slot_sibling_tags(workers, slot)
        if not is_exact_fleet(controller, tags):
            conflicts.append({"kind": kind, "slot": slot, "reason": "same-fleet name has foreign owner or generation"})
            return
        worker = workers.setdefault(slot, {"slot": slot, "resources": {}})
        if kind in worker["resources"]:
            raise ProviderError("worker slot has duplicate {} resources".format(kind))
        worker["resources"][kind] = resource_record(kind, value, power, tags_override=tags)

    for vm in vms:
        slot = slot_from_name(vm.get("name"), r"^vm-{}-wkr-".format(prefix))
        if slot is not None:
            add("vm", vm, slot, vm.get("powerState") or vm.get("power_state") or "unknown")
    for nic in nics:
        slot = slot_from_name(nic.get("name"), r"^nic-{}-wkr-".format(prefix))
        if slot is not None:
            add("nic", nic, slot)
    for disk in disks:
        slot = slot_from_name(disk.get("name"), r"^disk-{}-wkr-".format(prefix))
        if slot is None:
            continue
        name = str(disk.get("name"))
        if name.endswith("-os"):
            kind = "os-disk"
        elif name.endswith("-task"):
            kind = "task-disk"
        elif name.endswith("-account"):
            kind = "account-disk"
        else:
            conflicts.append({"kind": "disk", "slot": slot, "reason": "unrecognized worker disk name"})
            continue
        add(kind, disk, slot)
    identity_principals = {}
    for identity in identities:
        slot = slot_from_name(identity.get("name"), r"^id-{}-wkr-".format(prefix))
        if slot is not None:
            add("identity", identity, slot)
            principal = immutable_id("identity", identity)
            if principal:
                identity_principals[slot] = principal

    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    control_storage = "st{}ctl01".format(controller["prefix"])
    container_by_slot = {}
    for container in containers:
        match = re.match(r"^worker-state-([0-9]{2})$", str(container.get("name")))
        if not match:
            continue
        slot = int(match.group(1))
        if not 1 <= slot <= 16:
            continue
        metadata = partial_container_metadata(
            metadata_to_tags(container.get("metadata") or {}), slot, workers,
        )
        container_value = dict(container)
        container_value["id"] = (
            exact_id(controller, "Microsoft.Storage", "storageAccounts", storage)
            + "/blobServices/default/containers/" + container["name"]
        )
        container_by_slot[slot] = container_value
        add("state-container", container_value, slot, tags_override=metadata)
        blob_prefix = "worker/{:02d}/".format(slot)
        # A create interrupted before its lifecycle children leaves a slot
        # with template resources but no staging blobs; inventory classifies
        # that partial state instead of failing, and completeness gates still
        # refuse to adopt an incomplete worker.
        reservation = blob_record(
            controller, control_storage, "runner-control", blob_prefix + "reservation.json",
            "global-reservation", required=False,
        )
        request_blob = blob_record(
            controller, storage, container["name"], "request.json", "staging-request",
            required=False,
        )
        result_blob = blob_record(
            controller, storage, container["name"], "result.json", "staging-result",
            required=False,
        )
        for kind, blob in (
            ("global-reservation", reservation), ("staging-request", request_blob),
            ("staging-result", result_blob),
        ):
            if blob is not None:
                add(kind, blob, slot, tags_override=blob.get("tags") or metadata)

    for extension in extensions:
        slot = slot_from_name(extension.get("name"), r"^vm-{}-wkr-".format(prefix))
        if slot is None or not str(extension.get("name", "")).endswith("/AzureMonitorLinuxAgent"):
            continue
        vm_id = exact_id(
            controller, "Microsoft.Compute", "virtualMachines",
            expected_names(controller, slot)["vm"],
        )
        # The generic resource listing omits properties and etag; only the full
        # object carries an immutable child identity.
        value = show_full(controller, extension["id"])
        value["attached_to"] = vm_id
        value["properties"] = dict(value.get("properties") or {})
        value["properties"]["virtualMachineId"] = vm_id
        add("monitor-extension", value, slot)
    for command in run_commands:
        slot = slot_from_name(command.get("name"), r"^vm-{}-wkr-".format(prefix))
        if slot is None:
            continue
        child = str(command.get("name", "")).rsplit("/", 1)[-1]
        kind = {"bootstrap": "bootstrap-command", "execute": "task-command"}.get(child)
        if kind is None:
            conflicts.append({"kind": "run-command", "slot": slot, "reason": "undeclared worker Run Command child"})
            continue
        value = show_full(controller, command["id"])
        value["attached_to"] = exact_id(
            controller, "Microsoft.Compute", "virtualMachines",
            expected_names(controller, slot)["vm"],
        )
        value["properties"] = dict(value.get("properties") or {})
        value["properties"]["virtualMachineId"] = value["attached_to"]
        add(kind, value, slot)
    for schedule in schedules:
        slot = slot_from_name(schedule.get("name"), r"^shutdown-computevm-vm-{}-wkr-".format(prefix))
        if slot is not None:
            value = show_full(controller, schedule["id"], api_version="2018-09-15")
            value["properties"] = dict(value.get("properties") or {})
            value["properties"].setdefault("targetResourceId", exact_id(
                controller, "Microsoft.Compute", "virtualMachines",
                expected_names(controller, slot)["vm"],
            ))
            add("ttl-schedule", value, slot)

    for role in roles:
        scope = str(role.get("scope") or "")
        match = re.search(r"/containers/worker-state-([0-9]{2})$", scope, re.IGNORECASE)
        if not match:
            continue
        slot = int(match.group(1))
        if not 1 <= slot <= 16:
            continue
        principal = role.get("principalId")
        if identity_principals.get(slot) != principal:
            conflicts.append({"kind": "role-assignment", "slot": slot, "reason": "container role principal is not the exact slot identity"})
            continue
        role_value = dict(role)
        if not role_value.get("id"):
            role_value["id"] = role.get("roleAssignmentId")
        synthesized = {}
        if slot in workers:
            vm_tags = (workers[slot]["resources"].get("vm") or {}).get("tags") or {}
            synthesized = dict(vm_tags)
        if not synthesized:
            synthesized = {
                "workload": "firstmate",
                "deployment-generation": controller["deployment_generation"],
                "cleanup-owner": controller["owner"],
            }
        add("role-assignment", role_value, slot, tags_override=synthesized)

    # A worker may not gain public ingress or an identity other than its one
    # exact slot UAMI. These are provider-level acceptance invariants, not
    # optional controller policy.
    for slot, worker in workers.items():
        vm = worker["resources"].get("vm")
        nic = worker["resources"].get("nic")
        identity = worker["resources"].get("identity")
        if vm:
            vm_value = next(value for value in vms if str(value.get("id", "")).lower() == vm["id"].lower())
            identity_map = ((vm_value.get("identity") or {}).get("userAssignedIdentities") or {})
            if identity:
                if {key.lower() for key in identity_map} != {identity["id"].lower()}:
                    conflicts.append({"kind": "vm", "slot": slot, "reason": "VM cloud identity set is not exactly one slot identity"})
            elif identity_map:
                conflicts.append({"kind": "vm", "slot": slot, "reason": "VM has an unowned cloud identity"})
        if nic and nic.get("attached_to") and vm and nic["attached_to"].lower() != vm["id"].lower():
            conflicts.append({"kind": "nic", "slot": slot, "reason": "NIC is attached to another VM"})

    capacity_reservations, specialized_active_by_family = specialized_capacity_inventory(
        controller, vms, identities
    )
    result = {
        "schema": INVENTORY_SCHEMA,
        "observed_at": iso_utc(),
        "workers": [workers[slot] for slot in sorted(workers)],
        "capacity_reservations": capacity_reservations,
        "conflicts": conflicts,
        "metrics": metrics(
            controller, vms, capacity_reservations, specialized_active_by_family
        ) if include_metrics else {
            "actual_usd": None,
            "forecast_usd": None,
            "regional_limit_vcpus": None,
            "regional_used_vcpus": None,
            "specialized_active_vcpus": None,
            "specialized_active_by_family": {},
            "family_limit_vcpus": {},
            "family_used_vcpus": {},
            "family_free_vcpus": {},
            "sku_hourly_usd": {},
        },
    }
    return result


def worker_by_slot(snapshot, slot):
    matches = [worker for worker in snapshot["workers"] if worker["slot"] == slot]
    if len(matches) > 1:
        raise ProviderError("Azure returned duplicate worker slot inventory")
    return matches[0] if matches else None


def recorded_exact(
    action, worker, allow_missing=(), allow_previous_cloud_generation=False,
    skip_immutable=(), require_ready_children=True,
):
    if worker is None:
        raise ProviderError("exact worker slot is absent")
    resources = worker.get("resources") or {}
    expected = action.get("resources") or {}
    tags = action_tags({
        "deployment_generation": action["deployment_generation"],
        "owner": action["owner"],
    }, action)
    for kind in REQUIRED_RESOURCE_KINDS:
        current = resources.get(kind)
        prior = expected.get(kind)
        if current is None:
            if kind in allow_missing:
                continue
            raise ProviderError("exact {} resource is absent".format(kind))
        if prior is not None:
            if current.get("id") != prior.get("id"):
                raise ProviderIdentityRefusal(
                    "{} resource ID differs from the recorded assignment".format(kind)
                )
            # Compute-child provisioning state is mutable while each exact ARM
            # path stays fixed. Task commands and staging request/result blobs
            # also bind changing execution content through request/result
            # digests, so their path identity is the ownership fence here.
            if (
                kind not in skip_immutable
                and kind not in MUTABLE_PROVISIONING_CHILD_KINDS
                and kind not in ("staging-request", "staging-result")
                and current.get("immutable_id") != prior.get("immutable_id")
            ):
                raise ProviderIdentityRefusal(
                    "{} immutable identity differs from the recorded assignment".format(kind)
                )
        for key, value in tags.items():
            if kind in (
                "role-assignment", "state-container", "global-reservation",
                "staging-request", "staging-result",
            ) and key not in current.get("tags", {}):
                continue
            actual = current.get("tags", {}).get(key)
            if (
                allow_previous_cloud_generation
                and key == "cloud-generation"
                and actual == str(action.get("previous_cloud_generation"))
            ):
                continue
            if actual != value:
                raise ProviderError("{} exact task/account/worktree tag differs: {}".format(kind, key))
    vm_id = (resources.get("vm") or {}).get("id")
    for kind in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
        child = resources.get(kind)
        if child is not None and str(child.get("attached_to", "")).lower() != str(vm_id or "").lower():
            raise ProviderError("{} is not bound to the exact worker VM".format(kind))
    for kind in ("global-reservation", "staging-request", "staging-result"):
        blob = resources.get(kind)
        if blob is not None and (
            not re.fullmatch(r"[0-9a-f]{64}", str(blob.get("digest") or ""))
            or not isinstance(blob.get("length"), int)
            or blob["length"] < 0
        ):
            raise ProviderError("{} digest/length identity is incomplete".format(kind))
    ttl = resources.get("ttl-schedule")
    if ttl is not None and (
        str(ttl.get("status", "")).lower() != "enabled" or not ttl.get("deadline")
    ):
        raise ProviderError("worker TTL schedule is disabled or has no exact deadline")
    if require_ready_children:
        for kind in READY_CHILD_KINDS:
            child = resources.get(kind)
            if (
                child is not None
                and str(child.get("provisioning_state", "")).lower() != "succeeded"
            ):
                raise ProviderError("{} provisioning state is not succeeded".format(kind))
    return resources


def tag_resource(controller, resource_id, tags):
    _, rc, stderr = az(controller, [
        "tag", "update", "--resource-id", resource_id, "--operation", "Merge",
        "--tags",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags.items())], check=False)
    if rc != 0:
        raise ProviderError("exact worker resource tagging failed: {}".format(stderr))


def tag_container(controller, name, tags):
    _, rc, stderr = az(controller, [
        "storage", "container", "metadata", "update", "--auth-mode", "login",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
        "--name", name, "--metadata",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags_to_metadata(tags).items())], check=False)
    if rc != 0:
        raise ProviderError("exact worker state-container metadata update failed: {}".format(stderr))


def cleanup_marker(resource, key, value):
    return (resource.get("tags") or {}).get(key) == value


def mark_cleanup_container(controller, action, key, value):
    tags = action_tags(controller, action)
    tags[key] = value
    if key == "reset-action":
        tags["release-proof"] = action["release_proof_digest"]
    tag_container(
        controller, expected_names(controller, action["slot"])["state-container"], tags
    )


# What the reservation blob IDENTIFIES is the capacity grant: which slot, for
# which assignment generation, at which SKU and price. Everything else in it is
# provenance recorded alongside that grant, and must not be able to wedge a
# replay.
#
# ttl_deadline is recomputed from now() on every attempt, so it is volatile.
#
# The supervisor digest is NOT here at all, rather than being listed as
# volatile: it is the digest of the supervisor the bootstrap script carries,
# the guest re-proves it from the script it actually received, and a converging
# replay does not rewrite the blob, so keeping a copy would guarantee a stale
# one. Carrying it as identity was worse still: any merge touching
# bin/fm-worker-supervisor.py between a failed create and its replay turned a
# recoverable wedge into a permanent one whose only exit was hand-deleting the
# blob. That is not theoretical, it is the state slot 2 is in right now.
RESERVATION_VOLATILE_FIELDS = ("ttl_deadline",)


def blob_identity_digest(value, volatile_fields=()):
    """Digest of what IDENTIFIES this blob, ignoring fields that legitimately
    differ between attempts of the same action (a recomputed deadline, say)."""
    identity = {key: item for key, item in value.items() if key not in volatile_fields}
    return hashlib.sha256(canonical_bytes(identity) + b"\n").hexdigest()


def upload_json_blob(
    controller, account, container, name, value, tags, overwrite=False, volatile_fields=(),
):
    payload = canonical_bytes(value) + b"\n"
    digest = hashlib.sha256(payload).hexdigest()
    identity = blob_identity_digest(value, volatile_fields)
    fd, path = tempfile.mkstemp(prefix="fm-worker-blob-", suffix=".json")
    os.chmod(path, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        metadata = dict(tags_to_metadata(tags))
        metadata["content_digest"] = digest
        metadata["identity_digest"] = identity
        _, rc, stderr = az(controller, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", account,
            "--container-name", container, "--name", name, "--file", path,
            "--overwrite", "true" if overwrite else "false", "--metadata",
        ] + ["{}={}".format(key, value) for key, value in sorted(metadata.items())], check=False)
        if rc != 0:
            # A create-once blob that already carries exactly these bytes is
            # this same action replaying after a lost or timed-out response,
            # which must converge rather than wedge. Different bytes under the
            # same name still refuse: that is a foreign or newer assignment.
            if not overwrite and ("BlobAlreadyExists" in stderr or "already exists" in stderr):
                existing, show_rc, show_stderr = az(controller, [
                    "storage", "blob", "show", "--auth-mode", "login",
                    "--account-name", account, "--container-name", container,
                    "--name", name, "--query", "metadata.identity_digest",
                ], check=False)
                if show_rc != 0:
                    raise ProviderError(
                        "existing worker staging blob is unreadable: {}".format(show_stderr)
                    )
                if existing != identity:
                    raise ProviderError(
                        "worker staging blob {} already exists with different content".format(name)
                    )
                return digest
            raise ProviderError("exact worker staging upload failed: {}".format(stderr))
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(path).unlink()
    return digest


def upload_bytes_blob(controller, account, container, name, payload, tags):
    digest = hashlib.sha256(payload).hexdigest()
    fd, path = tempfile.mkstemp(prefix="fm-worker-payload-")
    os.chmod(path, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
        metadata = dict(tags_to_metadata(tags))
        metadata["content_digest"] = digest
        _, rc, stderr = az(controller, [
            "storage", "blob", "upload", "--auth-mode", "login", "--account-name", account,
            "--container-name", container, "--name", name, "--file", path,
            "--overwrite", "true", "--metadata",
        ] + ["{}={}".format(key, value) for key, value in sorted(metadata.items())],
            check=False, timeout=AZ_TIMEOUT_SECONDS + len(payload) // (256 * 1024))
        if rc != 0:
            raise ProviderError("exact worker payload upload failed: {}".format(stderr))
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(path).unlink()
    return digest


def outcome_blob_name(request_digest):
    if not re.fullmatch(r"[0-9a-f]{64}", str(request_digest)):
        raise ProviderError("outcome blob name requires an exact request digest")
    return "{}{}.bundle".format(OUTCOME_BLOB_PREFIX, request_digest[:32])


def blob_sas(controller, account, container, name, expiry_seconds, permissions="r"):
    """One short-lived user-delegation SAS over exactly one blob name.

    Inbound staging uses "r"; the outcome lane uses "cw" over exactly one blob
    name.

    This scopes the SAS, not the guest: the worker VM carries a user-assigned
    identity holding Storage Blob Data Contributor on its whole state
    container, so the guest can already reach every blob in it by IMDS. The
    narrow SAS is defense in depth and a clear contract, not a boundary the
    guest is held to. Landing safety comes from the digest in the signed
    result, which the controller checks before anything lands.
    """
    if permissions not in ("r", "cw"):
        raise ProviderError("worker blob SAS permissions are not one of the reviewed sets")
    expiry = (
        dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=expiry_seconds)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    uri, rc, stderr = az(
        controller,
        [
            "storage", "blob", "generate-sas", "--as-user", "--auth-mode", "login",
            "--https-only", "--account-name", account, "--container-name", container,
            "--name", name, "--permissions", permissions, "--expiry", expiry,
            "--full-uri",
        ],
        check=False,
    )
    if rc != 0 or not isinstance(uri, str) or not uri.strip().startswith("https://"):
        raise ProviderError("exact worker payload SAS creation failed: {}".format(stderr))
    return str(uri).strip()


def download_outcome_bundle(controller, account, container, name, expected_digest, expected_bytes, target):
    """Pull the guest-written outcome blob to the controller and prove it is
    exactly the bytes the digest-bound result committed to."""
    target = Path(target)
    if target.parent.is_symlink() or not target.parent.is_dir():
        raise ProviderError("outcome directory is unavailable")
    # Prove the blob is the size the signed result claims BEFORE fetching it.
    # The guest holds a write SAS, so without this the controller would pull
    # and buffer whatever it wrote, however large, and only then compare.
    properties, rc, stderr = az(controller, [
        "storage", "blob", "show", "--auth-mode", "login", "--account-name", account,
        "--container-name", container, "--name", name, "--query", "properties.contentLength",
    ], check=False)
    if rc != 0:
        raise ProviderError("outcome bundle properties are unreadable: {}".format(stderr))
    if not isinstance(properties, int) or properties != expected_bytes:
        raise ProviderError(
            "outcome blob size {} differs from the digest-bound result claim {}".format(
                properties, expected_bytes
            )
        )
    fd, staging = tempfile.mkstemp(prefix="fm-worker-outcome-", dir=str(target.parent))
    os.close(fd)
    try:
        os.chmod(staging, 0o600)
        # A 256 MiB ceiling cannot be moved inside the ordinary control-plane
        # call bound, so this transfer gets a bound proportional to its size.
        _, rc, stderr = az(controller, [
            "storage", "blob", "download", "--auth-mode", "login", "--account-name", account,
            "--container-name", container, "--name", name, "--file", staging, "--overwrite",
        ], check=False, timeout=AZ_TIMEOUT_SECONDS + expected_bytes // (256 * 1024))
        if rc != 0:
            raise ProviderError("outcome bundle download failed: {}".format(stderr))
        body = Path(staging).read_bytes()
        if len(body) != expected_bytes or hashlib.sha256(body).hexdigest() != expected_digest:
            raise ProviderError("outcome bundle differs from the digest-bound result")
        os.replace(staging, str(target))
    finally:
        with contextlib.suppress(FileNotFoundError):
            Path(staging).unlink()
    return len(body)


def require_session_blob_name(name, lane_prefix):
    """Refuse any blob name outside the compartment session/ namespace.

    The message lane is the one claim-exempt provider operation family, and
    this guard is where its boundary is ENFORCED rather than merely
    documented: every blob name a message op touches must live under
    session/ in the slot's own state container. message-put writes only
    session/in/... and message-collect reads only session/out/..., so the
    staging pair, the reservation record, and the outcome bundles are
    structurally unreachable from the message ops; a name outside the
    namespace, or a path-traversing alias for one, raises instead of being
    touched.
    """
    if (
        not isinstance(name, str)
        or not name.startswith(SESSION_BLOB_PREFIX)
        or ".." in name
        or "\\" in name
        or "\x00" in name
    ):
        raise ProviderError("message blob name is outside the session/ namespace")
    if not name.startswith(lane_prefix):
        raise ProviderError("message blob name is outside its {} lane".format(lane_prefix))
    return name


def verify_message_spec(message, required_field):
    """Exact-shape check for one message-lane request from the controller."""
    if not isinstance(message, dict):
        raise ProviderError("message lane request is malformed")
    slot = message.get("slot")
    if not isinstance(slot, int) or isinstance(slot, bool) or slot not in SKU_PLAN:
        raise ProviderError("message lane slot is outside the reviewed sixteen")
    bindings = message.get("bindings")
    required_bindings = (
        "home_binding", "task", "task_generation", "assignment_generation",
        "account_binding", "worktree_binding", "repository_binding",
        "repository_generation",
    )
    if not isinstance(bindings, dict) or any(
        not isinstance(bindings.get(field), str) or not bindings[field]
        for field in required_bindings
    ):
        raise ProviderError("message lane worker bindings are incomplete")
    if not isinstance(message.get("cloud_generation"), int) or isinstance(message.get("cloud_generation"), bool):
        raise ProviderError("message lane cloud generation is not exact")
    if message.get("role") not in ("author", "secondmate"):
        raise ProviderError("message lane worker role is not exact")
    if not isinstance(message.get(required_field), str) or not message[required_field]:
        raise ProviderError("message lane {} is absent".format(required_field))
    return slot


def message_put(controller, message):
    """Upload one bounded, content-addressed message blob to the compartment
    session inbox: session/in/<sha256>.json for the JSON lane, or
    session/in/attach/<sha256>.bundle for the attachment lane.

    CLAIM-EXEMPT BY DESIGN: this op is dispatched like inventory, outside the
    per-slot claim/lease/fence contract, because a leg's execute claim
    occupies pending_actions[slot] for its whole wall and a claimed message
    lane could never deliver during a leg. The exemption is safe only because
    this op touches no compute, no money, and no lifecycle state: it never
    runs a Run Command, never powers or deletes a resource, never edits
    controller state, and writes exactly one blob whose name it derives from
    the content digest. Idempotency comes from that content address: a replay
    of the same content converges on the existing blob without a second
    upload, and the same name holding different bytes refuses. Namespace
    boundary: every name this op writes must sit under session/in/ -
    require_session_blob_name raises on anything else.

    Role scope: until PR 4's spawn lane creates compartments, no secondmate
    worker exists to address, so the lane deliberately serves author-role
    workers as well as secondmate compartments; PR 4/6 narrows the callers
    to compartments. Delivery fencing (PR 4 contract): this transfer is
    slot-addressed and runs outside the controller lock, so a late put can
    land in a recreated slot's container; the monitor therefore stamps
    assignment_generation inside every message envelope and the session
    runner refuses envelopes naming a foreign generation (the runner half
    is DEFERRED: the closed inbox schema cannot carry the field yet, so the
    generation rides inside the nonce and only the controller's
    exact-assignment gate enforces it today).
    """
    slot = verify_message_spec(message, "file")
    lane = message.get("lane")
    if lane not in ("json", "attach"):
        raise ProviderError("message lane must be json or attach")
    source = Path(message["file"])
    if source.is_symlink() or not source.is_file():
        raise ProviderError("message payload file is unavailable")
    payload = source.read_bytes()
    if not payload:
        raise ProviderError("message payload is empty")
    if lane == "json":
        if len(payload) > MESSAGE_JSON_MAX_BYTES:
            raise ProviderError(
                "message payload exceeds its {}-byte bound".format(MESSAGE_JSON_MAX_BYTES))
        try:
            json.loads(payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ProviderError("message payload is not valid JSON")
        digest = hashlib.sha256(payload).hexdigest()
        name = "{}{}.json".format(MESSAGE_INBOX_PREFIX, digest)
    else:
        if len(payload) > MESSAGE_ATTACH_MAX_BYTES:
            raise ProviderError(
                "message attachment exceeds its {}-byte bound".format(MESSAGE_ATTACH_MAX_BYTES))
        digest = hashlib.sha256(payload).hexdigest()
        name = "{}{}.bundle".format(MESSAGE_ATTACH_PREFIX, digest)
    require_session_blob_name(name, MESSAGE_INBOX_PREFIX)
    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    container = expected_names(controller, slot)["state-container"]
    existing, rc, _stderr = az(controller, [
        "storage", "blob", "show", "--auth-mode", "login", "--account-name", storage,
        "--container-name", container, "--name", name,
    ], check=False)
    if rc == 0 and isinstance(existing, dict):
        properties = existing.get("properties", existing) or {}
        length = properties.get("contentLength")
        if length is None:
            length = existing.get("contentLength")
        metadata = existing.get("metadata") or properties.get("metadata") or {}
        remote_digest = metadata.get("content_digest") or metadata.get("content-digest")
        if remote_digest != digest or length != len(payload):
            # The name IS the content digest and this op's own upload path
            # always stamps content_digest metadata, so a missing or
            # different digest under this name (same-length different bytes
            # included) is corruption or a foreign writer, never a replay.
            raise ProviderError(
                "existing message blob {} differs from its content address".format(name))
        return {"blob_name": name, "sha256": digest, "bytes": len(payload), "replayed": True}
    tags = action_tags(controller, {
        "role": message["role"], "slot": slot,
        "cloud_generation": message["cloud_generation"], "bindings": message["bindings"],
    })
    uploaded = upload_bytes_blob(controller, storage, container, name, payload, tags)
    if uploaded != digest:
        raise ProviderError("message upload digest is not exact")
    return {"blob_name": name, "sha256": digest, "bytes": len(payload), "replayed": False}


def message_outbox_listing(controller, storage, container, after):
    """Name-ordered new outbox entries after the cursor, plus whether more
    remain beyond this call's bounded walk.

    The az listing is name-ordered, so the cursor (a local outbox name) is a
    deterministic high-water mark: entries at or before it are dropped
    client-side, and when a deep already-collected history fills whole
    listing pages the walk follows the service continuation marker for at
    most MESSAGE_COLLECT_MAX_PAGES pages. The walk stops early once one full
    processing page of new entries is in hand; anything beyond is reported
    as more rather than refused.
    """
    threshold = MESSAGE_OUTBOX_PREFIX + after if after else None
    entries = []
    marker = None
    for _page in range(MESSAGE_COLLECT_MAX_PAGES):
        arguments = [
            "storage", "blob", "list", "--auth-mode", "login", "--account-name", storage,
            "--container-name", container, "--prefix", MESSAGE_OUTBOX_PREFIX,
            "--num-results", str(MESSAGE_COLLECT_MAX_BLOBS), "--include", "m",
            "--show-next-marker",
        ]
        if marker:
            arguments += ["--marker", marker]
        listing, rc, stderr = az(controller, arguments, check=False)
        if rc != 0 or not isinstance(listing, list):
            raise ProviderError("message outbox listing failed or was malformed: {}".format(stderr))
        marker = None
        page = []
        for item in listing:
            if isinstance(item, dict) and "nextMarker" in item and "name" not in item:
                marker = item.get("nextMarker") or None
                continue
            if not isinstance(item, dict):
                raise ProviderError("message outbox listing entry is malformed")
            page.append(item)
        page.sort(key=lambda item: str(item.get("name", "")))
        for item in page:
            if threshold is not None and str(item.get("name", "")) <= threshold:
                continue
            entries.append(item)
            if len(entries) > MESSAGE_COLLECT_PAGE_BLOBS:
                # One entry beyond the processing page proves more remain;
                # the caller reports its cursor and the next call resumes.
                return entries[:MESSAGE_COLLECT_PAGE_BLOBS], True
        if marker is None:
            return entries, False
    return entries, True


def message_collect(controller, message):
    """Fetch new compartment outbox blobs (session/out/...) into one local
    directory and report their names, sizes, and SHA-256 digests, plus the
    cursor (last processed local name) and whether more remain.

    CLAIM-EXEMPT BY DESIGN, read-only, and shaped like inventory: dumb
    transport that touches no compute, no money, and no lifecycle state. It
    performs NO chain verification - the secondmate monitor owns the
    sequence/chain checks - and it never deletes or overwrites an existing
    local file. It also never re-downloads collected history: an existing
    local name is judged WITHOUT a transfer, against the listing's
    content_digest metadata when the writer stamped it (this provider's own
    uploads always do), or by exact size for digestless guest-written blobs;
    a digest or size mismatch refuses the collect, and a digestless
    same-size match is presumed already collected because the monitor's
    chain verification owns full integrity. Each call downloads at most
    MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES of new content and processes at
    most one bounded page of entries after the optional cursor; the summary
    reports the cursor and the more flag instead of ever hard-refusing a
    deep mailbox. Namespace boundary: the LIST is prefixed to session/out/
    and every returned name is re-checked through require_session_blob_name,
    so a listing that names any blob outside session/out/ refuses rather
    than fetching it.

    Role scope: until PR 4's spawn lane creates compartments, no secondmate
    worker exists to address, so the lane deliberately serves author-role
    workers as well as secondmate compartments; PR 4/6 narrows the callers
    to compartments.
    """
    slot = verify_message_spec(message, "output_dir")
    output_dir = Path(message["output_dir"])
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise ProviderError("message collect output directory is unavailable")
    after = message.get("after")
    if after is not None and (not isinstance(after, str) or not MESSAGE_LOCAL_NAME.match(after)):
        raise ProviderError("message collect cursor is malformed")
    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    container = expected_names(controller, slot)["state-container"]
    entries, more = message_outbox_listing(controller, storage, container, after)
    fetched = []
    skipped = []
    cursor = after
    spent = 0
    for blob in entries:
        name = require_session_blob_name(blob.get("name"), MESSAGE_OUTBOX_PREFIX)
        local_name = name[len(MESSAGE_OUTBOX_PREFIX):]
        if not MESSAGE_LOCAL_NAME.match(local_name):
            raise ProviderError(
                "message outbox blob name is unsupported: {}".format(str(name)[:200]))
        properties = blob.get("properties", blob) or {}
        length = properties.get("contentLength")
        if length is None:
            length = blob.get("contentLength")
        if not isinstance(length, int) or isinstance(length, bool) or not 0 <= length <= MESSAGE_ATTACH_MAX_BYTES:
            raise ProviderError("message outbox blob size is malformed or unbounded")
        target = output_dir / local_name
        if target.is_symlink():
            raise ProviderError(
                "message collect refuses a symlinked local target: {}".format(local_name))
        if target.exists():
            # Already-collected history is judged WITHOUT a transfer, or a
            # poll would re-pay the whole outbox on every call and a deep
            # history would eventually exceed any fixed deadline.
            local_bytes = target.read_bytes()
            local_digest = hashlib.sha256(local_bytes).hexdigest()
            metadata = blob.get("metadata") or properties.get("metadata") or {}
            remote_digest = metadata.get("content_digest") or metadata.get("content-digest")
            if remote_digest is not None:
                if remote_digest != local_digest:
                    raise ProviderError(
                        "collected message blob {} diverges from the existing local file".format(local_name))
            elif length != len(local_bytes):
                raise ProviderError(
                    "collected message blob {} diverges from the existing local file".format(local_name))
            skipped.append({"blob_name": name, "bytes": length, "sha256": local_digest})
            cursor = local_name
            continue
        if spent and spent + length > MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES:
            # Budget exhausted mid-walk: report the cursor and let the next
            # call continue. The first fetch of a call always fits because
            # no single blob exceeds the attach ceiling the budget equals.
            more = True
            break
        fd, staging = tempfile.mkstemp(prefix="fm-message-collect-", dir=str(output_dir))
        os.close(fd)
        try:
            os.chmod(staging, 0o600)
            _, download_rc, download_stderr = az(controller, [
                "storage", "blob", "download", "--auth-mode", "login", "--account-name", storage,
                "--container-name", container, "--name", name, "--file", staging, "--overwrite",
            ], check=False, timeout=AZ_TIMEOUT_SECONDS + length // (256 * 1024))
            if download_rc != 0:
                raise ProviderError("message blob download failed: {}".format(download_stderr))
            body = Path(staging).read_bytes()
            if len(body) != length:
                raise ProviderError("message blob size differs from its listing claim")
            digest = hashlib.sha256(body).hexdigest()
            os.replace(staging, str(target))
        finally:
            with contextlib.suppress(FileNotFoundError):
                Path(staging).unlink()
        spent += length
        fetched.append({"blob_name": name, "bytes": length, "sha256": digest})
        cursor = local_name
    return {"fetched": fetched, "skipped": skipped, "cursor": cursor, "more": more}


def staged_directory_archive(directory, manifest, label):
    """Deterministic tar of one flat staging directory, verified against the
    digest-bound request manifest before any byte leaves the controller."""
    root = Path(directory)
    if root.is_symlink() or not root.is_dir():
        raise ProviderError("{} staging directory is unavailable".format(label))
    seen = {}
    for name, expected in sorted(manifest.items()):
        entry = root / name
        if entry.is_symlink() or not entry.is_file():
            raise ProviderError("{} staging entry is not a regular file: {}".format(label, name))
        body = entry.read_bytes()
        if hashlib.sha256(body).hexdigest() != expected["sha256"] or len(body) != expected["bytes"]:
            raise ProviderError("{} staging entry differs from its bound manifest: {}".format(label, name))
        seen[name] = body
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name, body in sorted(seen.items()):
            info = tarfile.TarInfo(name=name)
            info.size = len(body)
            info.mode = 0o600
            info.mtime = 0
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            archive.addfile(info, io.BytesIO(body))
    return buffer.getvalue()


def run_command_instance_view(controller, vm_name, command_name):
    value, rc, stderr = az(controller, [
        "vm", "run-command", "show", "--resource-group", controller["resource_group"],
        "--vm-name", vm_name, "--name", command_name, "--instance-view",
    ], check=False)
    if rc != 0 or not isinstance(value, dict):
        raise ProviderError("worker Run Command instance view is unreadable: {}".format(stderr))
    view = value.get("instanceView") or {}
    if not isinstance(view, dict):
        raise ProviderError("worker Run Command instance view is malformed")
    return view


def marker_payload(text, marker):
    payloads = [
        line[len(marker):].strip()
        for line in str(text).splitlines()
        if line.strip().startswith(marker)
    ]
    if not payloads:
        return None
    try:
        return json.loads(payloads[-1])
    except json.JSONDecodeError as exc:
        raise ProviderError("guest marker payload is malformed: {}".format(exc))


def bootstrap_script(action):
    supervisor = (ROOT / "bin" / "fm-worker-supervisor.py").read_bytes()
    supervisor_digest = hashlib.sha256(supervisor).hexdigest()
    encoded = supervisor.hex()
    bindings = action["bindings"]
    script = """set -eu
umask 077
install -d -m 0755 /usr/local/libexec
python3 - <<'PY'
from pathlib import Path
payload=bytes.fromhex('{encoded}')
path=Path('/usr/local/libexec/fm-worker-supervisor')
path.write_bytes(payload)
path.chmod(0o755)
PY
printf '%s  %s\n' '{digest}' /usr/local/libexec/fm-worker-supervisor | sha256sum -c -
install -d -m 0700 /var/lib/firstmate-worker
cat > /var/lib/firstmate-worker/assignment.json <<'JSON'
{assignment}
JSON
prepare_disk() {{
  lun="$1"
  target="$2"
  device=""
  attempts=0
  # SCSI SKUs publish data disks under scsi1/lunN; NVMe-only SKUs (v6
  # families) publish them under data/by-lun/N via azure-vm-utils. Both are
  # udev identity paths; never guess raw namespaces because mkfs runs on the
  # resolved device.
  while [ "$attempts" -lt 30 ]; do
    for link in "/dev/disk/azure/scsi1/lun$lun" "/dev/disk/azure/data/by-lun/$lun"; do
      candidate=$(readlink -f "$link" 2>/dev/null || true)
      if [ -n "$candidate" ] && [ -b "$candidate" ]; then
        device="$candidate"
        break
      fi
    done
    if [ -n "$device" ]; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  if [ -z "$device" ] || [ ! -b "$device" ]; then
    echo "worker data disk lun $lun is absent" >&2
    exit 71
  fi
  if ! blkid "$device" >/dev/null 2>&1; then
    mkfs.ext4 -q -L "fm-lun$lun" "$device"
  fi
  install -d -m 0700 "$target"
  if ! mountpoint -q "$target"; then
    mount -o noatime,nodev,nosuid "$device" "$target"
  fi
  chmod 0700 "$target"
}}
prepare_disk 0 /mnt/account
prepare_disk 1 /mnt/task
""".format(
        encoded=encoded, digest=supervisor_digest,
        assignment=json.dumps({
            "home_binding": bindings["home_binding"], "task": bindings["task"],
            "task_generation": bindings["task_generation"],
            "assignment_generation": bindings["assignment_generation"],
            "account_binding": bindings["account_binding"],
            "worktree_binding": bindings["worktree_binding"],
            "repository_binding": bindings["repository_binding"],
            "repository_generation": bindings["repository_generation"],
            "supervisor_sha256": supervisor_digest,
        }, sort_keys=True, separators=(",", ":")),
    )
    return script, supervisor_digest


def worker_power_state(controller, vm_name):
    """The VM's PowerState code, lowercased, or "" when Azure reports none."""
    view, rc, stderr = az(controller, [
        "vm", "get-instance-view", "--resource-group", controller["resource_group"],
        "--name", vm_name, "--query",
        "instanceView.statuses[?starts_with(code, 'PowerState')].code",
    ], check=False)
    if rc != 0:
        raise ProviderError("exact worker power state is unreadable: {}".format(stderr))
    if not isinstance(view, list):
        view = [] if view is None else [view]
    for item in view:
        text = str(item).lower()
        if text.startswith("powerstate/"):
            return text.split("/", 1)[1]
    return ""


def ensure_worker_running(controller, vm_name):
    """Prove the worker is running, starting it if it is not.

    A create does not always build a new VM. The ARM deployment is idempotent,
    so a create that replays, or one that follows a failed attempt, converges
    onto the worker that already exists. Meanwhile the TTL shutdown schedule
    deallocates idle workers, so the VM a create converges onto is very often
    stopped. Azure then refuses the bootstrap run command outright with
    OperationNotAllowed, "Cannot modify extensions in the VM when the VM is not
    running", and nothing else in this provider can start compute: every other
    power operation here deallocates. The slot wedges with no owned way out.

    Transitional states matter and are not hypothetical. The TTL schedule fires
    daily, so `deallocating` and `stopping` are exactly what a create racing it
    sees, and issuing a start against an in-flight stop earns an ARM 409 rather
    than a running VM. Those are waited out before deciding.

    Returns whether it had to start the VM, so a caller can undo it.
    """
    deadline = time.monotonic() + VM_START_TIMEOUT_SECONDS
    started = False
    reads = 0
    while True:
        if reads >= VM_POWER_MAX_READS:
            raise ProviderError(
                "exact worker power state did not settle within {} reads".format(VM_POWER_MAX_READS)
            )
        reads += 1
        state = worker_power_state(controller, vm_name)
        if state == "running":
            return started
        if state in ("stopping", "deallocating", "starting"):
            # An in-flight power transition: a start now races it. Wait for the
            # state machine to settle rather than guessing.
            if time.monotonic() >= deadline:
                raise ProviderError(
                    "exact worker stayed in transitional power state {}".format(state)
                )
            time.sleep(VM_POWER_POLL_SECONDS)
            continue
        if started:
            # Already started once and it still is not running. Starting again
            # would loop; report the state Azure actually reports.
            if time.monotonic() >= deadline:
                raise ProviderError(
                    "exact worker did not reach running after a start: {}".format(state or "unknown")
                )
            time.sleep(VM_POWER_POLL_SECONDS)
            continue
        _, rc, stderr = az(controller, [
            "vm", "start", "--resource-group", controller["resource_group"], "--name", vm_name,
        ], check=False, timeout=VM_START_TIMEOUT_SECONDS)
        if rc != 0:
            raise ProviderError("exact worker compute could not be started: {}".format(stderr))
        started = True


def deallocate_started_worker(controller, vm_name):
    """Put back a worker this provider started, after a create failed.

    Without this a failed create leaves BILLABLE compute running that nothing
    reclaims: the controller records the worker as `creating`, classify_worker
    reports retained-for-investigation, and the reconcile loop only ever emits a
    deallocate for a worker carrying a release proof. Reclamation would fall to
    the daily TTL schedule, up to a full day of unattended compute per failed
    create. Best effort on purpose: the create's own error is what matters and
    must not be replaced by a cleanup error.
    """
    _, rc, stderr = az(controller, [
        "vm", "deallocate", "--resource-group", controller["resource_group"], "--name", vm_name,
    ], check=False, timeout=VM_START_TIMEOUT_SECONDS)
    if rc != 0:
        sys.stderr.write(
            "AZURE WORKER PROVIDER WARNING: started {} for a create that failed and could not "
            "put it back; it bills until its TTL schedule fires: {}\n".format(vm_name, stderr)
        )


def create_lifecycle_children(controller, action):
    """Start the worker if needed, build its children, and put it back on failure."""
    vm_name = expected_names(controller, action["slot"])["vm"]
    started = ensure_worker_running(controller, vm_name)
    try:
        return build_lifecycle_children(controller, action)
    except Exception:
        if started:
            # This provider started billable compute for a create that then
            # failed. Nothing else would put it back: the controller leaves the
            # worker `creating`, classify_worker reports
            # retained-for-investigation, and the reconcile loop only emits a
            # deallocate for a worker carrying a release proof.
            deallocate_started_worker(controller, vm_name)
        raise


def build_lifecycle_children(controller, action):
    names = expected_names(controller, action["slot"])
    vm_name = names["vm"]
    tags = action_tags(controller, action)
    script, supervisor_digest = bootstrap_script(action)
    # This BLOCKS on the guest exactly like the execute path does, and for the
    # same reason it cannot take the ordinary control-plane bound: the script
    # waits up to 60s per data disk for the device to appear, then runs mkfs
    # and the mounts. Under the default 300s the CLI gives up while the guest
    # carries on, and the controller records a failed create for a VM that is
    # in fact alive and finishing - the precise outcome
    # PROVIDER_CREATE_TIMEOUT_SECONDS exists to prevent, which it cannot do
    # from the outside while the inner bound fires 6900 seconds earlier.
    _, rc, stderr = az(controller, [
        "vm", "run-command", "create", "--resource-group", controller["resource_group"],
        "--vm-name", vm_name, "--name", names["bootstrap-command"],
        "--script", script, "--async-execution", "false",
        "--timeout-in-seconds", str(BOOTSTRAP_GUEST_TIMEOUT_SECONDS), "--tags",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags.items())], check=False,
        timeout=BOOTSTRAP_CLIENT_TIMEOUT_SECONDS)
    if rc != 0:
        raise ProviderError("pinned worker supervisor bootstrap failed: {}".format(stderr))
    # A managed Run Command reports create success even when the guest script
    # exits nonzero; only the instance view proves the bootstrap ran clean.
    view = run_command_instance_view(controller, vm_name, names["bootstrap-command"])
    if view.get("executionState") != "Succeeded" or view.get("exitCode") not in (0, None):
        raise ProviderError("pinned worker supervisor bootstrap failed in the guest: state={} exit={} error={}".format(
            view.get("executionState"), view.get("exitCode"), str(view.get("error", ""))[:500]
        ))
    execute_stub = "test -x /usr/local/libexec/fm-worker-supervisor && test -f /var/lib/firstmate-worker/request.json"
    _, rc, stderr = az(controller, [
        "vm", "run-command", "create", "--resource-group", controller["resource_group"],
        "--vm-name", vm_name, "--name", names["task-command"],
        "--script", execute_stub, "--async-execution", "true", "--tags",
    ] + ["{}={}".format(key, value) for key, value in sorted(tags.items())], check=False)
    if rc != 0:
        raise ProviderError("exact worker task Run Command creation failed: {}".format(stderr))
    deadline = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=6)).replace(second=0, microsecond=0)
    # `az resource create` has no --tags flag; a full object carries location,
    # tags, and properties together.
    ttl_object = json.dumps({
        "location": "eastus",
        "tags": tags,
        "properties": {
            "status": "Enabled", "taskType": "ComputeVmShutdownTask",
            "dailyRecurrence": {"time": deadline.strftime("%H%M")},
            "timeZoneId": "UTC", "targetResourceId": exact_id(
                controller, "Microsoft.Compute", "virtualMachines", vm_name
            ),
        },
    }, separators=(",", ":"))
    _, rc, stderr = az(controller, [
        "resource", "create", "--resource-group", controller["resource_group"],
        "--resource-type", "Microsoft.DevTestLab/schedules", "--api-version", "2018-09-15",
        "--name", names["ttl-schedule"], "--is-full-object", "--properties", ttl_object,
    ], check=False)
    if rc != 0:
        raise ProviderError("exact worker TTL schedule creation failed: {}".format(stderr))
    reservation = {
        "schema": "fm.worker-global-reservation/v1", "slot": action["slot"],
        "assignment_generation": action["bindings"]["assignment_generation"],
        "sku": action["sku"], "sku_family": action["sku_family"],
        "reservation_usd": action.get("reservation_usd"),
        # No supervisor_sha256 here. A converging replay returns without
        # rewriting the blob, so this field would be guaranteed stale after
        # exactly the event it was kept for, and a record that is reliably
        # wrong is worse than no record. Nothing reads it: the guest proves its
        # supervisor against the digest carried by the bootstrap script it was
        # actually handed, and staging-request keeps the live copy.
        "ttl_deadline": deadline.isoformat().replace("+00:00", "Z"),
    }
    upload_json_blob(
        controller, "st{}ctl01".format(controller["prefix"]), "runner-control",
        "worker/{:02d}/reservation.json".format(action["slot"]), reservation, tags,
        volatile_fields=RESERVATION_VOLATILE_FIELDS,
    )
    assignment = {
        "schema": "fm.worker-staging-request/v1", "status": "assigned",
        "slot": action["slot"], "bindings": action["bindings"],
        "supervisor_sha256": supervisor_digest,
    }
    # The staging pair is per-assignment WORKING state, not a claim on the slot.
    # mutate_execute overwrites both blobs with execution content, so create-once
    # here never actually guarded anything: after the first execute a resume
    # finds an fm.worker-execution/v1 body where it expects an assignment and
    # refuses forever. The reservation blob above is the one arbiter of who owns
    # this slot, and it stays strictly create-once.
    #
    # These must be REWRITTEN rather than converged onto: the guest verifies the
    # supervisor it was actually handed against this record, so a replay carrying
    # a newer supervisor has to leave the newer digest here, not the stale one.
    upload_json_blob(
        controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
        names["staging-request"], assignment, tags, overwrite=True,
    )
    pending_result = {
        "schema": "fm.worker-staging-result/v1", "status": "pending",
        "assignment_generation": action["bindings"]["assignment_generation"],
    }
    upload_json_blob(
        controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
        names["staging-result"], pending_result, tags, overwrite=True,
    )


def run_pilot_create(controller, action):
    if action.get("shared_admission_digest") != hashlib.sha256(canonical_bytes({
        "slot": action["slot"], "sku": action["sku"], "sku_family": action["sku_family"],
        "assignment_generation": action["bindings"]["assignment_generation"],
        "reservation_usd": action.get("reservation_usd"),
    })).hexdigest():
        raise ProviderError("singleton deployment lacks exact shared allocator admission proof")
    env = os.environ.copy()
    env.update({
        "FM_AZURE_CAPACITY_PROFILE": "full",
        "FM_AZURE_AUTHOR_CAPACITY_MODE": "mixed-current",
        "FM_AZURE_WORKER_HOME_BINDING": action["bindings"]["home_binding"],
        "FM_AZURE_WORKER_TASK_BINDING": action["bindings"]["task"],
        "FM_AZURE_WORKER_INVOCATION_BINDING": action["bindings"]["assignment_generation"],
        "FM_AZURE_WORKER_SNAPSHOT_DIGEST": "sha256:" + action["bindings"]["repository_binding"],
        "FM_AZURE_WORKER_COST_ATTRIBUTION": "author",
    })
    result = run([
        str(PILOT), "worker-create", "--slot", str(action["slot"]), "--confirm-create",
        "--confirm-subscription", controller["subscription"],
    ], check=False, timeout=3600, env=env)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()[-1500:]
        raise ProviderError("landed singleton worker deployment failed: {}".format(detail))


def converge_create_tags(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("new worker inventory contains foreign or unsafe resources")
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        raise ProviderError("worker deployment completed without exact slot resources")
    tags = action_tags(controller, action)
    for kind, resource in worker["resources"].items():
        if kind in (
            "role-assignment", "state-container", "global-reservation",
            "staging-request", "staging-result",
        ):
            continue
        tag_resource(controller, resource["id"], tags)
    tag_container(controller, expected_names(controller, action["slot"])["state-container"], tags)
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("tagged worker inventory contains foreign or unsafe resources")
    worker = worker_by_slot(snapshot, action["slot"])
    resources = recorded_exact(action, worker)
    if set(resources) != set(REQUIRED_RESOURCE_KINDS):
        raise ProviderError("worker create did not produce the complete exact resource set")
    return worker


def create_or_resume(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    if snapshot["conflicts"]:
        raise ProviderError("same-name foreign worker resources refuse create/adopt")
    existing = worker_by_slot(snapshot, action["slot"])
    reuse = action.get("reuse_retained") is True
    if existing is not None:
        resources = existing.get("resources") or {}
        if resources.get("vm"):
            try:
                recorded_exact(action, existing)
                # A fully converged worker returns from here without ever
                # reaching create_lifecycle_children, and the TTL schedule
                # deallocates idle workers daily. Returning one as-is reports
                # success while the controller marks the task assigned, and the
                # NEXT action, execute, hard-refuses deallocated compute with no
                # owned recovery: classify_worker only reports "deallocated" for
                # a worker carrying a release proof, so the reconcile loop never
                # starts or reclaims it. This is the case the whole change is
                # for, and it is the one that skips the create path entirely.
                if ensure_worker_running(controller, expected_names(controller, action["slot"])["vm"]):
                    existing = worker_by_slot(
                        inventory(controller, include_metrics=False), action["slot"]
                    )
                return existing
            except ProviderError:
                # A submitted create can be visible with the template's exact VM
                # bindings before child tag convergence. It is safe to replay the
                # same landed incremental deployment and complete the same action.
                vm_tags = resources["vm"].get("tags") or {}
                bindings = action["bindings"]
                if not (
                    vm_tags.get("home-binding") == bindings["home_binding"]
                    and vm_tags.get("task-binding") == bindings["task"]
                    and vm_tags.get("invocation-binding") == bindings["assignment_generation"]
                ):
                    raise ProviderError("visible worker belongs to another task or generation")
        elif reuse:
            recorded_exact(
                action, existing, allow_missing=("vm", "nic", "os-disk"),
                allow_previous_cloud_generation=True,
            )
        else:
            # A deployment interrupted before the VM leaves bindingless or
            # exactly-bound template children. Replaying the same landed
            # incremental deployment is safe only when every present resource
            # carries this action's exact bindings or none at all.
            bindings = action["bindings"]
            for kind, resource in resources.items():
                tags = resource.get("tags") or {}
                for tag_name, expected in (
                    ("home-binding", bindings["home_binding"]),
                    ("task-binding", bindings["task"]),
                    ("invocation-binding", bindings["assignment_generation"]),
                ):
                    value = tags.get(tag_name)
                    if value not in (None, "", expected):
                        raise ProviderError("fresh assignment found retained slot resources and refuses to inherit them")
    elif reuse:
        raise ProviderError("dirty-task resume found no exact retained capacity")
    run_pilot_create(controller, action)
    create_lifecycle_children(controller, action)
    return converge_create_tags(controller, action)


def wait_absent(controller, resource_id, timeout=180):
    url = "https://management.azure.com{}?api-version=2024-03-01".format(resource_id)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        _, rc, _ = az(controller, ["rest", "--method", "get", "--url", url], check=False)
        if rc != 0:
            return
        time.sleep(2)
    raise ProviderError("Azure resource remained after bounded exact deletion")


def conditional_delete(controller, kind, resource):
    etag = resource.get("etag")
    url = "https://management.azure.com{}?api-version={}".format(resource["id"], RESOURCE_API[kind])
    arguments = ["rest", "--method", "delete", "--url", url]
    if etag:
        arguments += ["--headers", "If-Match={}".format(etag)]
    elif kind != "role-assignment":
        # Compute, MSI and DevTestLab reads supply no ETag, so If-Match cannot
        # guard those kinds. The deletion window is narrowed instead by
        # re-reading the exact resource immediately before an exact-ID delete
        # and requiring its immutable identity to match the recorded
        # assignment. Role assignments keep their principal/role identity pair
        # as before.
        current = show_full(controller, resource["id"])
        if immutable_id(kind, current) != resource.get("immutable_id"):
            raise ProviderError("{} immutable identity changed; conditional deletion refuses".format(kind))
    _, rc, stderr = az(controller, arguments, check=False)
    if rc != 0:
        raise ProviderError("conditional {} deletion failed: {}".format(kind, stderr))


def mutate_deallocate(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    resources = recorded_exact(
        action, worker_by_slot(snapshot, action["slot"]), require_ready_children=False
    )
    power = str(resources["vm"].get("power_state", "")).lower()
    if "deallocated" not in power:
        _, rc, stderr = az(controller, [
            "vm", "deallocate", "--resource-group", controller["resource_group"],
            "--name", expected_names(controller, action["slot"])["vm"],
        ], check=False)
        if rc != 0:
            raise ProviderError("exact worker deallocation failed: {}".format(stderr))
    final = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    final_resources = recorded_exact(action, final, require_ready_children=False)
    if "deallocated" not in str(final_resources["vm"].get("power_state", "")).lower():
        raise ProviderError("worker compute did not reach Azure deallocated state")
    return final


def mutate_delete_compute(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        raise ProviderError("compute cleanup lost exact retained task/account ownership")
    resources = worker.get("resources") or {}
    container = resources.get("state-container")
    marked = container is not None and cleanup_marker(
        container, "compute-action", action["idempotency_key"]
    )
    if not marked:
        resources = recorded_exact(action, worker, require_ready_children=False)
        if "deallocated" not in str(resources["vm"].get("power_state", "")).lower():
            raise ProviderError("compute deletion requires the exact deallocated worker")
        mark_cleanup_container(
            controller, action, "compute-action", action["idempotency_key"]
        )
        worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    # ttl-schedule may be absent only on re-entry after the VM already
    # cascaded away (Azure deletes shutdown-computevm schedules with their
    # target VM); the fresh-entry path above still required it alongside the
    # live deallocated VM.
    resources = recorded_exact(
        action, worker, allow_missing=(
            "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command", "task-command",
            "ttl-schedule",
        ),
        skip_immutable=("state-container",), require_ready_children=False,
    )
    if resources.get("ttl-schedule") is None and resources.get("vm") is not None:
        raise ProviderError("TTL disappeared while the worker VM still exists")
    worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if worker is None:
        raise ProviderError("VM deletion also lost exact retained task/account capacity")
    remaining = worker.get("resources") or {}
    for kind in (
        "task-command", "bootstrap-command", "monitor-extension", "vm", "nic", "os-disk",
    ):
        resource = remaining.get(kind)
        if resource is None:
            continue
        if kind in ("task-command", "bootstrap-command", "monitor-extension"):
            # Azure refuses modifying VM children while the VM is deallocated,
            # and these child resources cannot outlive their VM: the exact VM
            # deletion below cascades them, and the post-deletion snapshot
            # proves their absence.
            continue
        if kind == "vm":
            if "deallocated" not in str(resource.get("power_state", "")).lower():
                raise ProviderError("compute deletion requires the exact deallocated worker")
            conditional_delete(controller, kind, resource)
            wait_absent(controller, resource["id"])
            # NIC/disk attach relations only clear once the VM is gone, so the
            # detach proof below must read a fresh snapshot.
            refreshed = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
            if refreshed is None:
                raise ProviderError("VM deletion also lost exact retained task/account capacity")
            remaining = refreshed.get("resources") or {}
            for child in ("task-command", "bootstrap-command", "monitor-extension"):
                if remaining.get(child) is not None:
                    raise ProviderError("worker VM deletion left a {} child".format(child))
            continue
        if kind in ("nic", "os-disk"):
            if resource.get("attached_to"):
                raise ProviderError("{} did not detach from the deleted worker VM".format(kind))
            prior = action["resources"].get(kind)
            if prior is None or resource["id"] != prior["id"] or resource["immutable_id"] != prior["immutable_id"]:
                raise ProviderError("detached {} immutable identity changed".format(kind))
        conditional_delete(controller, kind, resource)
    final = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if final is None:
        raise ProviderError("compute cleanup lost retained task/account ownership")
    final_resources = final.get("resources") or {}
    compute_kinds = (
        "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command", "task-command",
    )
    if any(kind in final_resources for kind in compute_kinds):
        raise ProviderError("disposable VM/NIC/OS/child capacity remains after exact cleanup")
    ttl = final_resources.get("ttl-schedule")
    if ttl is not None:
        conditional_delete(controller, "ttl-schedule", ttl)
        final = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
        if final is None:
            raise ProviderError("TTL cleanup lost retained task/account ownership")
    # An absent TTL here is the Azure cascade outcome: shutdown-computevm
    # schedules delete with their target VM, VM absence was proved just above,
    # and entry exactness proved the TTL alive alongside the live VM, so the
    # bound held for the worker's whole compute lifetime.
    recorded_exact(
        action, final, allow_missing=compute_kinds + ("ttl-schedule",),
        skip_immutable=("state-container",), require_ready_children=False,
    )
    return final


def mutate_reset(controller, action):
    if not re.match(r"^[0-9a-f]{64}$", str(action.get("release_proof_digest", ""))):
        raise ProviderError("reset requires the exact ordinary release-proof digest")
    snapshot = inventory(controller, include_metrics=False)
    worker = worker_by_slot(snapshot, action["slot"])
    if worker is None:
        return None
    resources = worker.get("resources") or {}
    container = resources.get("state-container")
    marked = (
        container is not None
        and cleanup_marker(container, "reset-action", action["idempotency_key"])
        and cleanup_marker(container, "release-proof", action["release_proof_digest"])
    )
    if not marked:
        disposable = (
            "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command", "task-command",
            "ttl-schedule",
        )
        resources = recorded_exact(
            action, worker, allow_missing=disposable, require_ready_children=False
        )
        if any(kind in resources for kind in disposable):
            raise ProviderError("reset refuses while disposable compute still exists")
        mark_cleanup_container(
            controller, action, "reset-action", action["idempotency_key"]
        )
        worker = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    allow_missing = tuple(kind for kind in REQUIRED_RESOURCE_KINDS if kind != "state-container")
    resources = recorded_exact(
        action, worker, allow_missing=allow_missing, skip_immutable=("state-container",),
        require_ready_children=False,
    )
    if any(kind in resources for kind in (
        "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command", "task-command",
        "ttl-schedule",
    )):
        raise ProviderError("reset refuses while disposable compute or children still exist")
    for kind in (
        "staging-result", "staging-request", "global-reservation", "role-assignment",
        "identity", "account-disk", "task-disk",
    ):
        resource = resources.get(kind)
        if resource is None:
            continue
        if kind in ("account-disk", "task-disk") and resource.get("attached_to"):
            raise ProviderError("retained {} is still attached".format(kind))
        if kind in ("staging-result", "staging-request", "global-reservation"):
            account = "st{}ctl01".format(controller["prefix"]) if kind == "global-reservation" else os.environ.get("FM_AZURE_STORAGE_NAME", "")
            container_name = "runner-control" if kind == "global-reservation" else expected_names(controller, action["slot"])["state-container"]
            blob_name = (
                "worker/{:02d}/reservation.json".format(action["slot"])
                if kind == "global-reservation" else expected_names(controller, action["slot"])[kind]
            )
            _, rc, stderr = az(controller, [
                "storage", "blob", "delete", "--auth-mode", "login", "--account-name", account,
                "--container-name", container_name, "--name", blob_name,
                "--if-match", resource["etag"],
            ], check=False)
            if rc != 0:
                raise ProviderError("conditional {} blob deletion failed: {}".format(kind, stderr))
        else:
            conditional_delete(controller, kind, resource)
    # The payload and account archives are per-execution transport (their
    # content is bound through the request manifests, never identity-fenced),
    # and the account archive fronts provider credentials: both are removed
    # unconditionally at reset, tolerating absence.
    state_container_name = expected_names(controller, action["slot"])["state-container"]
    for blob_name in ("payload.tar.gz", "account.tar.gz"):
        _, rc, stderr = az(controller, [
            "storage", "blob", "delete", "--auth-mode", "login",
            "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
            "--container-name", state_container_name,
            "--name", blob_name,
        ], check=False)
        if rc != 0 and "does not exist" not in stderr and "BlobNotFound" not in stderr:
            raise ProviderError("staging archive deletion failed for {}: {}".format(blob_name, stderr))
    refreshed = worker_by_slot(inventory(controller, include_metrics=False), action["slot"])
    if refreshed is None:
        raise ProviderError("cleanup marker container disappeared before exact reset completed")
    state_container = (refreshed.get("resources") or {}).get("state-container")
    if state_container is None or not cleanup_marker(
        state_container, "reset-action", action["idempotency_key"]
    ):
        raise ProviderError("reset cleanup marker is absent before container deletion")
    # The Blob service supports no ETag precondition on container deletion;
    # If-Unmodified-Since against the freshly-read lastModified is its
    # strongest supported guard. The marker write above already bumped
    # lastModified and this record postdates it, so any foreign write in the
    # remaining window fails the precondition.
    if not state_container.get("last_modified"):
        raise ProviderError("state-container modification identity is absent; conditional deletion refuses")
    # Storage listings stamp lastModified with a +00:00 offset; the CLI's
    # datetime parser wants the Z form of the same UTC instant.
    unmodified_since = str(state_container["last_modified"]).replace("+00:00", "Z")
    _, rc, stderr = az(controller, [
        "storage", "container", "delete", "--auth-mode", "login",
        "--account-name", os.environ.get("FM_AZURE_STORAGE_NAME", ""),
        "--name", expected_names(controller, action["slot"])["state-container"],
        "--if-unmodified-since", unmodified_since,
    ], check=False)
    if rc != 0:
        raise ProviderError("exact worker state-container deletion failed: {}".format(stderr))
    final = inventory(controller, include_metrics=False)
    if worker_by_slot(final, action["slot"]) is not None:
        raise ProviderError("released worker capacity remains after exact reset")
    return None


def execute_generation_line(action):
    bindings = action["bindings"]
    return "export FM_WORKER_ASSIGNMENT_GENERATION='{}' FM_WORKER_ACCOUNT_BINDING='{}'".format(
        bindings["assignment_generation"], bindings["account_binding"]
    )


def build_execute_script(action):
    request = action["request"]
    request_json = json.dumps(request, sort_keys=True, separators=(",", ":"))
    bindings = action["bindings"]
    supervisor_prelude = ""
    supervisor_command = "/usr/local/libexec/fm-worker-supervisor"
    if request.get("existing_task_disk"):
        try:
            supervisor_body = (ROOT / "bin" / "fm-worker-supervisor.py").read_bytes()
        except OSError as exc:
            raise ProviderError(
                "existing task-disk recovery supervisor is unreadable: {}".format(exc)
            ) from None
        supervisor_digest = hashlib.sha256(supervisor_body).hexdigest()
        if request.get("supervisor_sha256") != supervisor_digest:
            raise ProviderError("existing task-disk recovery supervisor binding differs")
        supervisor_path = "/var/lib/firstmate-worker/recovery-supervisor-{}.py".format(
            supervisor_digest
        )
        supervisor_prelude = """printf '%s' '{body}' | /usr/bin/base64 --decode > '{path}'
[ "$(/usr/bin/sha256sum '{path}' | /usr/bin/awk '{{print $1}}')" = '{digest}' ]
chmod 0700 '{path}'
""".format(
            body=base64.b64encode(supervisor_body).decode("ascii"),
            path=supervisor_path,
            digest=supervisor_digest,
        )
        supervisor_command = "/usr/bin/python3 '{}'".format(supervisor_path)
    return """set -eu
umask 077
install -d -m 0700 /var/lib/firstmate-worker
cat > /var/lib/firstmate-worker/request.json <<'JSON'
{request}
JSON
export FM_WORKER_HOME_BINDING='{home}' FM_WORKER_TASK='{task}' FM_WORKER_TASK_GENERATION='{task_generation}'
{generation_line}
export FM_WORKER_WORKTREE_BINDING='{worktree}' FM_WORKER_REPOSITORY_BINDING='{repository}'
export FM_WORKER_REPOSITORY_GENERATION='{repository_generation}' FM_WORKER_CLOUD_INSTANCE_ID='{cloud}'
export FM_WORKER_WORKTREE=/mnt/task FM_WORKER_ACCOUNT_HOME=/mnt/account
{supervisor_prelude}{supervisor_command} execute --request /var/lib/firstmate-worker/request.json --result /var/lib/firstmate-worker/result.json
printf 'FM-WORKER-RESULT:%s\\n' "$(cat /var/lib/firstmate-worker/result.json)"
""".format(
        request=request_json, home=bindings["home_binding"], task=bindings["task"],
        task_generation=bindings["task_generation"], generation_line=execute_generation_line(action),
        worktree=bindings["worktree_binding"],
        repository=bindings["repository_binding"], repository_generation=bindings["repository_generation"],
        cloud=action["cloud_instance_id"], supervisor_prelude=supervisor_prelude,
        supervisor_command=supervisor_command,
    )


def initial_execute_staging_pair(action):
    try:
        supervisor_bytes = (ROOT / "bin" / "fm-worker-supervisor.py").read_bytes()
    except OSError as exc:
        raise ProviderError(
            "exact initial worker supervisor is unreadable: {}".format(str(exc)[:300])
        ) from None
    supervisor_digest = hashlib.sha256(supervisor_bytes).hexdigest()
    return {
        "staging-request": {
            "schema": "fm.worker-staging-request/v1",
            "status": "assigned",
            "slot": action["slot"],
            "bindings": action["bindings"],
            "supervisor_sha256": supervisor_digest,
        },
        "staging-result": {
            "schema": "fm.worker-staging-result/v1",
            "status": "pending",
            "assignment_generation": action["bindings"]["assignment_generation"],
        },
    }


def initial_execute_staging_is_exact(action, resources):
    for kind, value in initial_execute_staging_pair(action).items():
        payload = canonical_bytes(value) + b"\n"
        resource = resources.get(kind) or {}
        if (
            resource.get("digest") != hashlib.sha256(payload).hexdigest()
            or resource.get("length") != len(payload)
        ):
            return False
    return True


def run_command_execution_binding(live):
    properties = live.get("properties") or {}
    tags = live.get("tags") or properties.get("tags") or {}
    request_digest = tags.get(EXECUTION_REQUEST_TAG)
    idempotency_key = tags.get(EXECUTION_IDEMPOTENCY_TAG)
    if request_digest is None and idempotency_key is None:
        return None
    if (
        not isinstance(request_digest, str)
        or not re.fullmatch(r"[0-9a-f]{64}", request_digest)
        or not isinstance(idempotency_key, str)
        or not re.fullmatch(r"[0-9a-f]{64}", idempotency_key)
    ):
        raise ProviderError("worker task Run Command execution binding tags are malformed")
    return request_digest, idempotency_key


def exact_execution_marker(view):
    execution = marker_payload(
        "{}\n{}".format(view.get("output", ""), view.get("error", "")),
        "FM-WORKER-RESULT:",
    )
    if execution is None:
        return None
    if not isinstance(execution, dict) or execution.get("schema") != EXECUTION_RESULT_SCHEMA:
        raise ProviderError("worker task Run Command result marker schema is not exact")
    supplied = execution.get("result_digest")
    unsigned = dict(execution)
    unsigned.pop("result_digest", None)
    if supplied != hashlib.sha256(canonical_bytes(unsigned)).hexdigest():
        raise ProviderError("recovered private worker result digest is not exact")
    return execution


def execute_terminal_disposition(controller, action, resources):
    task_command_resource = resources.get("task-command") if isinstance(resources, dict) else None
    if not isinstance(task_command_resource, dict) or not task_command_resource.get("id"):
        return EXECUTE_DISPOSITION_SUBMIT, None
    live = show_full(controller, task_command_resource["id"])
    properties = live.get("properties") or {}
    source = properties.get("source") or live.get("source") or {}
    stored_script = source.get("script") if isinstance(source, dict) else None
    expected_script = build_execute_script(action)
    request_digest = action.get("request_digest")
    idempotency_key = action.get("idempotency_key")
    binding = run_command_execution_binding(live)
    current_binding = (request_digest, idempotency_key)
    substantive_script = isinstance(stored_script, str) and bool(stored_script.strip())
    exact_script = substantive_script and stored_script == expected_script
    fallback_bound = (
        substantive_script
        and isinstance(request_digest, str)
        and re.fullmatch(r"[0-9a-f]{64}", request_digest)
        and request_digest in stored_script
        and execute_generation_line(action) in stored_script.splitlines()
    )
    view = None
    if binding is not None and binding != current_binding:
        if exact_script or fallback_bound:
            raise ProviderError("worker task Run Command script and execution binding tags disagree")
        view = run_command_instance_view(
            controller, expected_names(controller, action["slot"])["vm"],
            expected_names(controller, action["slot"])["task-command"],
        )
        previous = exact_execution_marker(view)
        if (
            view.get("executionState") == "Succeeded"
            and isinstance(previous, dict)
            and previous.get("request_digest") == binding[0]
        ):
            return EXECUTE_DISPOSITION_SUBMIT, None
        raise ProviderError("worker task Run Command has an ambiguous prior execution binding")
    if not substantive_script:
        if binding is None:
            if not initial_execute_staging_is_exact(action, resources):
                raise ProviderError(
                    "existing worker task Run Command source is unreadable outside the exact initial staging state"
                )
            view = run_command_instance_view(
                controller, expected_names(controller, action["slot"])["vm"],
                expected_names(controller, action["slot"])["task-command"],
            )
            if (
                view.get("executionState") == "Failed"
                and str(view.get("exitCode")) == "-202"
                and exact_execution_marker(view) is None
            ):
                return EXECUTE_DISPOSITION_SUBMIT, None
            raise ProviderError("worker task Run Command does not prove the exact initial preflight stub")
    elif not exact_script and not fallback_bound:
        if binding == current_binding:
            raise ProviderError("worker task Run Command source disagrees with its exact execution binding")
        return EXECUTE_DISPOSITION_SUBMIT, None
    provisioning_state = properties.get("provisioningState") or live.get("provisioningState")
    if str(provisioning_state).lower() in ("failed", "canceled"):
        return EXECUTE_DISPOSITION_TERMINAL, {
            "schema": EXECUTION_TERMINAL_SCHEMA,
            "request_digest": request_digest,
            "idempotency_key": action.get("idempotency_key"),
            "disposition": "provider-terminal",
            "provisioning_state": provisioning_state,
            "task_command_id": task_command_resource["id"],
        }
    if str(provisioning_state).lower() != "succeeded":
        raise ProviderError(
            "exact worker execution remains bound and nonterminal: state={}".format(
                provisioning_state
            )
        )
    names = expected_names(controller, action["slot"])
    view = view or run_command_instance_view(controller, names["vm"], names["task-command"])
    if view.get("executionState") != "Succeeded":
        raise ProviderError(
            "exact worker execution has no recoverable terminal result: state={}".format(
                view.get("executionState")
            )
        )
    execution = exact_execution_marker(view)
    if not isinstance(execution, dict) or execution.get("request_digest") != request_digest:
        raise ProviderError("exact worker execution has no request-bound result marker")
    return EXECUTE_DISPOSITION_RECOVERED, execution


def persist_execute_result(controller, action, names, tags, execution):
    request = action["request"]
    if request.get("outcome_expected") and (
        execution.get("outcome_present") or execution.get("return_present")
    ):
        outcome_target = action.get("outcome_dir")
        if not outcome_target:
            raise ProviderError("execution collected an outcome with no controller directory to land it in")
        # The guest records where it actually put the bytes. Anything but the
        # staging blob means the upload was diverted (a test sink, an injected
        # unprotected FM_WORKER_OUTCOME_FILE), and the result must not be
        # treated as a collectable outcome.
        if execution.get("outcome_sink", "") != "blob":
            raise ProviderError(
                "execution claims an outcome written to {!r} rather than the staging blob".format(
                    execution.get("outcome_sink")
                )
            )
        digest_claim = execution.get("outcome_sha256")
        bytes_claim = execution.get("outcome_bytes")
        if not isinstance(digest_claim, str) or not re.fullmatch(r"[0-9a-f]{64}", digest_claim):
            raise ProviderError("execution outcome digest is malformed")
        if not isinstance(bytes_claim, int) or isinstance(bytes_claim, bool) or not 0 < bytes_claim <= MAX_OUTCOME_BYTES:
            raise ProviderError("execution outcome size is malformed or unbounded")
        download_outcome_bundle(
            controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
            outcome_blob_name(request["request_digest"]), digest_claim, bytes_claim,
            Path(outcome_target) / "outcome.bundle",
        )
    upload_json_blob(
        controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
        names["staging-result"], execution, tags, overwrite=True,
    )


def mutate_execute(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    worker = worker_by_slot(snapshot, action["slot"])
    resources = recorded_exact(action, worker)
    request = action.get("request")
    if not isinstance(request, dict) or request.get("request_digest") != action.get("request_digest"):
        raise ProviderError("execution request identity is not exact")
    names = expected_names(controller, action["slot"])
    tags = action_tags(controller, action)
    disposition, recovered = execute_terminal_disposition(
        controller, action, resources
    )
    if disposition in (EXECUTE_DISPOSITION_TERMINAL, EXECUTE_DISPOSITION_RECOVERED):
        if disposition == EXECUTE_DISPOSITION_RECOVERED:
            persist_execute_result(controller, action, names, tags, recovered)
        return worker, recovered
    if disposition != EXECUTE_DISPOSITION_SUBMIT:
        raise ProviderError("worker execution disposition is unsupported")
    if "deallocated" in str(resources["vm"].get("power_state", "")).lower():
        raise ProviderError("execute refuses deallocated worker compute")
    upload_json_blob(
        controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
        names["staging-request"], request, tags, overwrite=True,
    )
    # Crewmate payload plane: the digest-bound request carries only manifests;
    # the archives ride private blobs and reach the guest over short-lived
    # read-only user-delegation SAS bounded to the wall plus collection slack.
    # The SAS URLs travel as PROTECTED run-command parameters: ARM GET and
    # az vm run-command show expose the ordinary resource and binding tags but
    # never protected parameters, so the account-archive SAS is not readable
    # off the control plane for its validity window. The managed agent delivers
    # parameters as environment variables for the script process, which the
    # supervisor inherits.
    protected_parameters = []
    if action.get("payload_dir"):
        storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
        sas_seconds = int(request["wall_seconds"]) + CLIENT_WAIT_SLACK_SECONDS
        for label, directory, manifest in (
            ("payload", action["payload_dir"], request["payload_files"]),
            ("account", action["account_dir"], request["account_files"]),
        ):
            archive = staged_directory_archive(directory, manifest, label)
            blob_name = "{}.tar.gz".format(label)
            archive_digest = upload_bytes_blob(
                controller, storage, names["state-container"], blob_name, archive, tags,
            )
            sas_url = blob_sas(
                controller, storage, names["state-container"], blob_name, sas_seconds,
            )
            if not re.fullmatch(r"https://[A-Za-z0-9.:/_?&=%+-]+", sas_url):
                raise ProviderError("{} staging SAS carries unsupported characters".format(label))
            prefix = "FM_WORKER_{}_".format(label.upper())
            protected_parameters += [
                prefix + "URL=" + sas_url,
                prefix + "SHA256=" + archive_digest,
                prefix + "BYTES=" + str(len(archive)),
            ]
    if request.get("outcome_expected"):
        # Landing v1 return path: the guest gets create/write on exactly one
        # blob name and no forge or provider credential at all. What it writes
        # is only landable after the digest in the signed result matches.
        # The guest uploads AFTER staging and after the full wall, so a SAS
        # measured from mint time must cover both or a slow clone silently
        # expires the credential and the crewmate's commits die with the VM.
        outcome_sas = blob_sas(
            controller, os.environ.get("FM_AZURE_STORAGE_NAME", ""), names["state-container"],
            outcome_blob_name(request["request_digest"]),
            int(request["wall_seconds"]) + CLIENT_WAIT_SLACK_SECONDS, permissions="cw",
        )
        if not re.fullmatch(r"https://[A-Za-z0-9.:/_?&=%+-]+", outcome_sas):
            raise ProviderError("outcome staging SAS carries unsupported characters")
        protected_parameters.append("FM_WORKER_OUTCOME_URL=" + outcome_sas)
    script = build_execute_script(action)
    execution_tags = dict(tags)
    execution_tags.update({
        EXECUTION_REQUEST_TAG: action["request_digest"],
        EXECUTION_IDEMPOTENCY_TAG: action["idempotency_key"],
    })
    update_command = [
        "vm", "run-command", "update", "--resource-group", controller["resource_group"],
        "--vm-name", names["vm"], "--name", names["task-command"],
        "--script", script, "--async-execution", "false",
        # Without this the managed run command takes Azure's own default while
        # the CLI waits out the whole wall, so a long task dies guest-side with
        # the client still blocked. bin/fm-azure-runner.py and
        # bin/fm-azure-validation.py both set it for the same reason.
        "--timeout-in-seconds", str(int(request["wall_seconds"]) + GUEST_RUN_SLACK_SECONDS),
        "--tags",
    ] + [
        "{}={}".format(key, value) for key, value in sorted(execution_tags.items())
    ]
    if protected_parameters:
        update_command += ["--protected-parameters"] + protected_parameters
    # This call BLOCKS until the guest script finishes, so it cannot share the
    # ordinary control-plane bound: a wall of up to six hours under a
    # 300-second CLI timeout means no real crewmate task can ever return its
    # result, and every smoke that passed before was a sub-second command.
    _, rc, stderr = az(
        controller, update_command, check=False,
        timeout=int(request["wall_seconds"]) + CLIENT_WAIT_SLACK_SECONDS,
    )
    if rc != 0:
        raise ProviderError("exact private worker execution failed: {}".format(stderr))
    # The update response body has no instance view; only the explicit
    # instance-view read returns the guest's marker-framed result line.
    view = run_command_instance_view(controller, names["vm"], names["task-command"])
    if view.get("executionState") != "Succeeded":
        raise ProviderError("private worker execution did not complete in the guest: state={} error={}".format(
            view.get("executionState"), str(view.get("error", ""))[:500]
        ))
    execution = exact_execution_marker(view)
    if execution is None:
        raise ProviderError("private worker execution returned no exact result")
    persist_execute_result(controller, action, names, tags, execution)
    return worker_by_slot(inventory(controller, include_metrics=False), action["slot"]), execution


def mutate_steer(controller, action):
    snapshot = inventory(controller, include_metrics=False)
    resources = recorded_exact(action, worker_by_slot(snapshot, action["slot"]))
    if "deallocated" in str(resources["vm"].get("power_state", "")).lower():
        raise ProviderError("steer refuses deallocated worker compute")
    digest = action.get("request_digest")
    if not re.match(r"^[0-9a-f]{64}$", str(digest)):
        raise ProviderError("steer request digest is malformed")
    bindings = action["bindings"]
    script = """set -eu
supervisor=/usr/local/libexec/fm-worker-supervisor
[ -x \"$supervisor\" ] || { echo 'minimal worker supervisor absent' >&2; exit 70; }
exec \"$supervisor\" steer --home-binding '{}' --task '{}' --task-generation '{}' --assignment-generation '{}' --request-digest '{}'
""".format(
        bindings["home_binding"], bindings["task"], bindings["task_generation"],
        bindings["assignment_generation"], digest,
    )
    output, rc, stderr = az(controller, [
        "vm", "run-command", "invoke", "--resource-group", controller["resource_group"],
        "--name", expected_names(controller, action["slot"])["vm"],
        "--command-id", "RunShellScript", "--scripts", script,
    ], check=False, timeout=STEER_CLIENT_TIMEOUT_SECONDS)
    if rc != 0:
        raise ProviderError("exact guest-supervisor steer failed: {}".format(stderr))
    # RunShellScript never propagates the guest exit code, so only the
    # supervisor's digest-bound acknowledgement proves the steer landed.
    messages = "\n".join(
        str(item.get("message", ""))
        for item in (output.get("value") or [])
        if isinstance(item, dict)
    ) if isinstance(output, dict) else ""
    ack = marker_payload(messages, "FM-WORKER-STEER-ACK:")
    if (
        ack is None
        or ack.get("request_digest") != digest
        or ack.get("assignment_generation") != bindings["assignment_generation"]
    ):
        raise ProviderError("guest supervisor did not acknowledge the exact steer request")
    return worker_by_slot(inventory(controller, include_metrics=False), action["slot"])


def mutate(controller, action):
    if not isinstance(action, dict):
        raise ProviderError("provider mutation action is malformed")
    action_type = action.get("type")
    if action_type not in ("create", "resume", "deallocate", "delete-compute", "reset", "execute", "steer"):
        raise ProviderError("unsupported provider mutation action")
    if action.get("deployment_generation") != controller["deployment_generation"] or action.get("owner") != controller["owner"]:
        raise ProviderError("provider mutation owner or deployment generation is not exact")
    if not isinstance(action.get("slot"), int) or action["slot"] not in SKU_PLAN:
        raise ProviderError("provider mutation slot is outside the reviewed sixteen")
    expected_sku, expected_family = SKU_PLAN[action["slot"]]
    if action.get("sku") != expected_sku or action.get("sku_family") != expected_family:
        raise ProviderError("provider mutation SKU/family is not the reviewed mixed plan")
    expected_key = hashlib.sha256(canonical_bytes({
        key: value for key, value in action.items() if key != "idempotency_key"
    })).hexdigest()
    if action.get("idempotency_key") != expected_key:
        raise ProviderError("provider mutation idempotency key is not exact")
    if action_type in ("create", "resume"):
        worker = create_or_resume(controller, action)
    elif action_type == "deallocate":
        worker = mutate_deallocate(controller, action)
    elif action_type == "delete-compute":
        worker = mutate_delete_compute(controller, action)
    elif action_type == "reset":
        worker = mutate_reset(controller, action)
    elif action_type == "execute":
        worker, execution = mutate_execute(controller, action)
    else:
        worker = mutate_steer(controller, action)
    result = {
        "idempotency_key": action["idempotency_key"],
        "action": action_type,
    }
    if worker is not None:
        result["worker"] = worker
    if action_type == "execute":
        result["execution"] = execution
    return result


def read_request():
    data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(data) > MAX_INPUT_BYTES:
        raise ProviderError("provider request exceeds its bounded input allowance")
    try:
        request = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProviderError("provider request is malformed: {}".format(exc))
    if not isinstance(request, dict) or request.get("schema") != REQUEST_SCHEMA:
        raise ProviderError("provider request schema is not supported")
    controller = request.get("controller")
    if not isinstance(controller, dict):
        raise ProviderError("provider controller binding is absent")
    required = ("home_binding", "subscription", "deployment_generation", "owner", "prefix", "resource_group")
    if any(not isinstance(controller.get(field), str) or not controller[field] for field in required):
        raise ProviderError("provider controller binding is incomplete")
    if controller["subscription"].lower() != os.environ.get("FM_AZURE_SUBSCRIPTION_ID", "").lower():
        raise ProviderError("provider request subscription differs from the out-of-band Azure scope")
    if controller["deployment_generation"] != os.environ.get("FM_AZURE_DEPLOYMENT_GENERATION"):
        raise ProviderError("provider request deployment generation differs from the out-of-band scope")
    if controller["owner"] != os.environ.get("FM_AZURE_OWNER_TAG"):
        raise ProviderError("provider request cleanup owner differs from the out-of-band scope")
    if controller["prefix"] != os.environ.get("FM_AZURE_NAMING_PREFIX"):
        raise ProviderError("provider request naming prefix differs from the out-of-band scope")
    storage = os.environ.get("FM_AZURE_STORAGE_NAME", "")
    if not re.match(r"^[a-z0-9]{3,24}$", storage):
        raise ProviderError("FM_AZURE_STORAGE_NAME is required with exact Azure storage syntax")
    return request, controller


def response(controller, operation, **fields):
    value = {
        "schema": RESPONSE_SCHEMA,
        "operation": operation,
        "controller": controller,
    }
    value.update(fields)
    return value


def main():
    request, controller = read_request()
    operation = request.get("operation")
    if operation == "inventory":
        value = response(controller, operation, inventory=inventory(controller))
    elif operation == "mutate":
        require_landed_code()
        value = response(controller, operation, result=mutate(controller, request.get("action")))
    elif operation in ("message-put", "message-collect"):
        # The claim-exempt compartment message lane, dispatched like
        # inventory: no landed-code gate (that gate owns compute mutations),
        # no claim, no lease. The ops themselves bound payload size, require
        # content-addressed names, and refuse any blob outside session/.
        handler = message_put if operation == "message-put" else message_collect
        value = response(controller, operation, result=handler(controller, request.get("action")))
    else:
        raise ProviderError("provider operation is not supported")
    sys.stdout.buffer.write(canonical_bytes(value) + b"\n")


if __name__ == "__main__":
    try:
        main()
    except ProviderIdentityRefusal as exc:
        print("AZURE WORKER PROVIDER REFUSED-IDENTITY: {}".format(exc), file=sys.stderr)
        raise SystemExit(3)
    except ProviderError as exc:
        print("AZURE WORKER PROVIDER REFUSED: {}".format(exc), file=sys.stderr)
        raise SystemExit(2)
