#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Hermetic queue, budget, fencing, reset, recovery, and classification coverage
# for the provider-neutral elastic worker lifecycle and Azure adapter contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROLLER="$ROOT/bin/fm-worker-lifecycle.py"
WRAPPER="$ROOT/bin/fm-worker-lifecycle.sh"
AZURE="$ROOT/bin/fm-azure-worker-provider.py"
SUPERVISOR="$ROOT/bin/fm-worker-supervisor.py"
AUTHORITY="$ROOT/bin/fm-worker-authority.py"
DOC="$ROOT/docs/azure-workers.md"
SUB=11111111-1111-4111-8111-111111111111

static_contract() {
  python3 - "$CONTROLLER" "$AZURE" "$SUPERVISOR" "$AUTHORITY" "$DOC" <<'PY' || fail "elastic worker static contract failed"
from pathlib import Path
import sys

controller = Path(sys.argv[1]).read_text(encoding="utf-8")
azure = Path(sys.argv[2]).read_text(encoding="utf-8")
supervisor = Path(sys.argv[3]).read_text(encoding="utf-8")
authority = Path(sys.argv[4]).read_text(encoding="utf-8")
doc = Path(sys.argv[5]).read_text(encoding="utf-8")
# The operator contract in docs/azure-workers.md owns the queue's mutations. A
# new one that is not written there leaves the doc stating, wrongly, that
# release is the only exit.
# Not a bare substring: `<!-- there is no withdraw -->` satisfied that while
# saying the opposite. Require the contract sentence, outside any comment.
withdraw_doc_lines = [
    line for line in doc.splitlines()
    if "withdraw" in line and not line.lstrip().startswith("<!--")
]
assert withdraw_doc_lines, "docs/azure-workers.md does not document the withdraw queue mutation"
assert any(
    "queued" in line and "credential" in line for line in withdraw_doc_lines
), ("docs/azure-workers.md mentions withdraw without stating what it accepts or that it "
    "removes the staged credential", withdraw_doc_lines)
assert any(
    "Release remains the only exit" in line for line in doc.splitlines()
    if not line.lstrip().startswith("<!--")
), "docs/azure-workers.md no longer states that release owns work which held capacity"
surrender_doc_lines = [
    line for line in doc.splitlines()
    if "surrender" in line.lower() and not line.lstrip().startswith("<!--")
]
assert any(
    "refusal-first" in line and "--confirm-discard-unlanded" in line
    for line in surrender_doc_lines
), ("docs/azure-workers.md mentions surrender without its refusal-first gates "
    "and the unlanded-work confirmation", surrender_doc_lines)
for marker in (
    '"assigned", "clean-warm", "deallocated", "orphaned-safe-to-delete", "retained-for-investigation"',
    "REGIONAL_ADMISSION_CEILING_VCPUS = 128", "AUTHOR_PLAN_VCPUS = MAX_WORKERS * VCPUS_PER_WORKER",
    "SPECIALIZED_SHAPE_VCPUS = 40", "SHARED_HEADROOM_VCPUS = 22", "MAX_WORKERS = 16",
    'FM_AZURE_WORKER_WARM_IDLE currently must remain zero', "pending_action",
    "pending_actions", "LEGACY_PENDING_SENTINEL", "superseded-by-pending-actions",
    "revision moved from", "FencedState", "slot_lease", "LOCK_NB", "provider_mutate",
    "drain_pending", "claim_pending", "apply_pending", "command_abandon_claim",
    "capacity-reserve", "capacity-reserve-shape", "capacity-release", "merged_specialized_reservations",
    "command_withdraw", "command_surrender", "WORKER AUTHORITY REFUSED",
    "--confirm-discard-unlanded",
    "REVIEWED_CONTROL_SKU_FAMILY", "command_capacity_reserve_shape",
    "fm.worker-authority/v1", "authority-receipt", "fm.worker-execution/v1",
):
    assert marker in controller, marker
assert 'shape.add_argument("--required"' not in controller
assert '"fetch", "--quiet", "--no-tags", "--prune", "origin"' in authority
for marker in (
    "run_pilot_create", "conditional_delete", "If-Match=", "reuse_retained",
    '"role", "assignment", "list", "--all"',
    "same-name foreign", "/usr/local/libexec/fm-worker-supervisor", "create_lifecycle_children",
    "prepare_disk 0 /mnt/account", "prepare_disk 1 /mnt/task", "blkid",
    "/dev/disk/azure/scsi1/lun", "/dev/disk/azure/data/by-lun/",
    '"bootstrap-command"', '"task-command"', '"ttl-schedule"', '"global-reservation"',
    '"staging-request"', '"staging-result"',
    "worker NIC has a public IP relation", "VM cloud identity set is not exactly one slot identity",
):
    assert marker in azure, marker
for marker in ("fm.worker-execution/v1", "request_digest", "subprocess.run", "MAX_OUTPUT_BYTES"):
    assert marker in supervisor, marker
for marker in ("endpoint_evidence", "report_evidence", "landing_evidence", "account_evidence", "worktree_evidence"):
    assert marker in authority, marker
for marker in (
    "sixteen 4-vCPU workers", "$1,500", "3,500 aggregate author worker-hours",
    "downloaded self-contained form artifact", "returns through a file",
    "Combined author and specialized demand beyond the shared 128-vCPU ceiling remains queued",
    "max(Azure observed usage, exact active fleet vCPUs)",
    "commissioning path no longer bypasses cumulative actual or forecast admission",
    "No capacity reservation creates an always-on worker pool",
    "Every acceptance leg needs a positive control", "warm-idle target is zero",
):
    assert marker in doc, marker
assert "hosted form service" in doc and "force-delete" in doc
PY
  pass "provider seam, Azure identity fencing, cost boundary, Lavish contract, and acceptance controls are documented"
}

classification_and_admission_matrix() {
  python3 - "$CONTROLLER" <<'PY' || fail "classification/admission matrix failed"
import copy
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("lifecycle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

env = {
    "max_workers": 16, "planning_hours": 3500.0, "policy_phase": "commissioning",
    "commissioning_ceiling_usd": 1500.0, "steady_target_usd": 1000.0,
    "admission_hours": 24.0, "cooldown_seconds": 300, "warm_idle": 0,
}
state = {
    "queue": {}, "workers": {}, "completed_worker_seconds": 0.0,
    "cleanup_refusals": [], "next_assignment": 1,
}
item = {
    "schema": module.REQUEST_SCHEMA, "task": "task-one", "task_generation": "task-gen",
    "repository_generation": "repo-gen", "home_binding": "1" * 64,
    "account_binding": "2" * 64, "worktree_binding": "3" * 64,
    "repository_binding": "4" * 64, "owner_kind": "primary", "role": "author",
    "eligible": True, "discretionary": True, "status": "queued", "enqueued_at": "2026-01-01T00:00:00Z",
}
module.verify_request(item)
worker = module.create_worker_record(
    dict(env, deployment_generation="dep", owner="owner"), state, 1, item, 10.0
)
tags = module.expected_tags(worker)
resources = {}
for kind in module.REQUIRED_RESOURCE_KINDS:
    resources[kind] = {
        "id": "/slot/1/" + kind, "immutable_id": "immutable-" + kind,
        "tags": dict(tags),
    }
resources["vm"]["power_state"] = "VM running"
resources["nic"]["attached_to"] = resources["vm"]["id"]
for kind in ("os-disk", "task-disk", "account-disk"):
    resources[kind]["attached_to"] = resources["vm"]["id"]
cloud = {"slot": 1, "resources": resources}
worker["resources"] = {kind: module.resource_identity(value) for kind, value in resources.items()}
worker["cloud_instance_id"] = resources["vm"]["immutable_id"]
worker["phase"] = "assigned"
worker["assigned_at"] = "2026-01-01T00:00:00Z"

assert module.classify_worker(worker, cloud)[0] == "assigned"
warm = copy.deepcopy(worker)
warm["bindings"]["task"] = "unbound"
warm_tags = module.expected_tags(warm)
for value in cloud["resources"].values():
    value["tags"] = dict(warm_tags)
assert module.classify_worker(warm, cloud)[0] == "clean-warm"
for value in cloud["resources"].values():
    value["tags"] = dict(tags)
released = copy.deepcopy(worker)
released["release_proof"] = {"proof_digest": "5" * 64}
released["cooldown_started_at"] = "2026-01-01T00:00:00Z"
deallocated = copy.deepcopy(cloud)
deallocated["resources"]["vm"]["power_state"] = "VM deallocated"
assert module.classify_worker(released, deallocated)[0] == "deallocated"
residual = copy.deepcopy(cloud)
for kind in ("vm", "nic", "os-disk"):
    residual["resources"].pop(kind)
released["phase"] = "compute-removed"
assert module.classify_worker(released, residual)[0] == "orphaned-safe-to-delete"
assert module.classify_worker(worker, residual)[0] == "retained-for-investigation"
foreign = copy.deepcopy(cloud)
foreign["resources"]["task-disk"]["immutable_id"] = "foreign"
assert module.classify_worker(worker, foreign)[0] == "retained-for-investigation"
assert module.classify_worker(worker, None)[0] == "retained-for-investigation"

# Staging blobs are per-execution transport: their identity changes after an
# execute and must not wedge classification, while every other kind still
# fences on identity (the task-disk case above).
executed = copy.deepcopy(cloud)
executed["resources"]["staging-request"]["immutable_id"] = "post-execute-etag"
executed["resources"]["staging-result"]["immutable_id"] = "post-execute-etag-2"
assert module.classify_worker(worker, executed)[0] == "assigned"
released_executed = copy.deepcopy(released)
released_executed["phase"] = "assigned"
executed_dark = copy.deepcopy(executed)
executed_dark["resources"]["vm"]["power_state"] = "VM deallocated"
assert module.classify_worker(released_executed, executed_dark)[0] == "deallocated"

metrics = {
    "actual_usd": 100.0, "forecast_usd": 200.0,
    "regional_limit_vcpus": 128, "regional_used_vcpus": 2,
    "specialized_active_vcpus": 0,
    "specialized_active_by_family": {},
    "family_limit_vcpus": {family: 10 for _, family in module.SKU_PLAN.values()},
    "family_used_vcpus": {family: 0 for _, family in module.SKU_PLAN.values()},
    "family_free_vcpus": {family: 10 for _, family in module.SKU_PLAN.values()},
    "sku_hourly_usd": {sku: 0.25 for sku, _ in module.SKU_PLAN.values()},
}
inventory = {"metrics": metrics, "workers": [], "capacity_reservations": [], "conflicts": []}
assert module.admission_result(env, state, inventory, 1, item)[0] is True
for field in ("actual_usd", "forecast_usd"):
    changed = copy.deepcopy(inventory)
    changed["metrics"][field] = None
    assert module.admission_result(env, state, changed, 1, item)[0] is False
# Bootstrap-only untrained-forecast seam: with the operator's explicit
# commissioning confirmation, any unreadable forecast (the exact untrained
# refusal or a throttle-exhausted read against the same untrained endpoint)
# substitutes the readable actual as the conservative forecast; without the
# confirmation, or with an unreadable actual, admission still refuses.
untrained = copy.deepcopy(inventory)
untrained["metrics"]["forecast_usd"] = None
untrained["metrics"]["forecast_untrained"] = True
assert module.admission_result(env, state, untrained, 1, item)[0] is False
os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"] = "1"
try:
    assert module.admission_result(env, state, untrained, 1, item)[0] is True
    plain_unreadable = copy.deepcopy(inventory)
    plain_unreadable["metrics"]["forecast_usd"] = None
    assert module.admission_result(env, state, plain_unreadable, 1, item)[0] is True
    no_actual = copy.deepcopy(untrained)
    no_actual["metrics"]["actual_usd"] = None
    assert module.admission_result(env, state, no_actual, 1, item)[0] is False
finally:
    del os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"]
plain_unreadable = copy.deepcopy(inventory)
plain_unreadable["metrics"]["forecast_usd"] = None
assert module.admission_result(env, state, plain_unreadable, 1, item)[0] is False
# The reserve report carries the seam-substituted forecast, so an admission
# that relied on the substitution never reads as omitted evidence.
assert module.reported_forecast(True, 3.25, None) == 3.25
assert module.reported_forecast(False, 3.25, None) is None
assert module.reported_forecast(True, None, None) is None
assert module.reported_forecast(True, 3.25, 7.5) == 7.5
changed = copy.deepcopy(inventory)
changed["metrics"]["regional_limit_vcpus"] = 127
assert module.admission_result(env, state, changed, 1, item)[0] is False
changed = copy.deepcopy(inventory)
changed["metrics"]["family_used_vcpus"] = None
assert module.admission_result(env, state, changed, 1, item)[0] is False
active_specialized = []
specialized_families = [
    family for _, family in module.SKU_PLAN.values() if family != module.SKU_PLAN[1][1]
]
for index in range(10):
    family = specialized_families[index % len(specialized_families)]
    sku = next(sku for sku, candidate_family in module.REVIEWED_SKU_FAMILY.items() if candidate_family == family)
    active_specialized.append({
        "reservation_id": "azr-{:012x}".format(index + 1), "role": "specialized",
        "sku": sku, "sku_family": family, "vcpus": 4,
        "amount_usd": 1.0, "active": True,
    })
changed = copy.deepcopy(inventory)
changed["capacity_reservations"] = active_specialized
changed["metrics"].update({"regional_used_vcpus": 102, "specialized_active_vcpus": 40})
assert module.admission_result(env, state, changed, 1, item)[0] is True
changed["metrics"]["regional_used_vcpus"] = 106
assert module.admission_result(env, state, changed, 1, item)[0] is False
changed = copy.deepcopy(inventory)
family = module.SKU_PLAN[1][1]
changed["metrics"]["family_used_vcpus"][family] = 8
assert module.admission_result(env, state, changed, 1, item)[0] is False
changed = copy.deepcopy(inventory)
changed["metrics"]["forecast_usd"] = 1499.0
assert module.admission_result(env, state, changed, 1, item)[0] is False
required = dict(item, discretionary=False)
assert module.admission_result(env, state, changed, 1, required)[0] is True

# Sixteen distinct queued tasks produce a sixteen-worker desired burst, while
# the seventeenth remains demand rather than becoming a seventeenth VM.
for index in range(17):
    queued = dict(item)
    queued.update({
        "task": "task-{}".format(index), "task_generation": "gen-{}".format(index),
        "account_binding": format(index + 10, "064x"),
        "worktree_binding": format(index + 100, "064x"),
    })
    state["queue"][module.request_key(queued["task"], queued["task_generation"])] = queued
assert module.desired_count(env, state, inventory) == 16
specialized = copy.deepcopy(inventory)
specialized["capacity_reservations"] = active_specialized
for reservation in active_specialized:
    family = reservation["sku_family"]
    specialized["metrics"]["family_used_vcpus"][family] = min(
        8, specialized["metrics"]["family_used_vcpus"].get(family, 0) + 4
    )
specialized["metrics"].update({"regional_used_vcpus": 42, "specialized_active_vcpus": 40})
assert module.desired_count(env, state, specialized) < 16
budgeted = copy.deepcopy(inventory)
budgeted["metrics"]["actual_usd"] = 1499.0
budgeted["metrics"]["forecast_usd"] = 1499.0
assert module.desired_count(env, state, budgeted) == 0

# One pending disposable-runner reservation consumes exact family, regional,
# specialized-shape, and shared actual/forecast budget in the same admission.
pending_runner = {
    "reservation_id": "azr-ffffffffffff", "role": "specialized",
    "sku": "Standard_D4as_v6", "sku_family": "standardDav6Family",
    "vcpus": 4, "amount_usd": 50.0, "active": False,
}
with_runner = copy.deepcopy(inventory)
with_runner["capacity_reservations"] = [pending_runner]
commitments = module.capacity_commitments(state, with_runner)
assert commitments["regional_committed"] == 6
assert commitments["family_committed"]["standardDav6Family"] == 4
assert commitments["specialized_committed"] == 4
assert module.outstanding_cost_reservations(state, with_runner) == 50.0
family_full = copy.deepcopy(with_runner)
family_full["metrics"]["family_used_vcpus"]["standardDav6Family"] = 8
assert module.admission_result(env, state, family_full, 1, item)[0] is False
budget_full = copy.deepcopy(with_runner)
budget_full["metrics"]["forecast_usd"] = 1450.0
assert module.admission_result(env, state, budget_full, 1, item)[0] is False
conflicting_local = copy.deepcopy(state)
conflicting_local["capacity_reservations"] = {
    "azr-ffffffffffff": {
        "status": "reserved", "role": "specialized", "sku": "Standard_D4as_v7",
        "sku_family": "StandardDasv7Family", "vcpus": 4, "amount_usd": 50.0,
    }
}
try:
    module.merged_specialized_reservations(conflicting_local, with_runner)
except module.LifecycleError as exc:
    assert "differs" in str(exc)
else:
    raise AssertionError("conflicting local/provider runner reservation was accepted")

# Duplicate account and worktree ownership refuse independently.
existing = next(iter(state["queue"].values()))
try:
    module.ensure_unique_bindings(state, dict(
        item, task="other", account_binding=existing["account_binding"], worktree_binding="9" * 64
    ))
except module.LifecycleError as exc:
    assert "provider-account" in str(exc)
else:
    raise AssertionError("shared account lease was accepted")
try:
    module.ensure_unique_bindings(state, dict(
        item, task="other", account_binding="9" * 64, worktree_binding=existing["worktree_binding"]
    ))
except module.LifecycleError as exc:
    assert "worktree" in str(exc)
else:
    raise AssertionError("shared writable worktree was accepted")
PY
  pass "all reconciliation classes and quota, cost, shared-account, shared-worktree refusal controls distinguish unsafe state"
}

azure_provider_refusal_matrix() {
  python3 - "$AZURE" <<'PY' || fail "Azure provider refusal matrix failed"
import copy
import hashlib
import importlib.util
import json
import sys

spec = importlib.util.spec_from_file_location("azure_provider", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
controller = {
    "subscription": "11111111-1111-4111-8111-111111111111",
    "resource_group": "rg", "deployment_generation": "dep", "owner": "owner", "prefix": "fmtest",
}
action = {
    "type": "deallocate", "slot": 1, "sku": "Standard_D4as_v6",
    "sku_family": "standardDav6Family", "cloud_generation": 1,
    "deployment_generation": "dep", "owner": "owner", "cloud_instance_id": "vm-instance",
    "bindings": {
        "home_binding": "1" * 64, "task": "task", "task_generation": "task-gen",
        "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
        "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
        "repository_generation": "repo-gen",
    },
}
tags = module.action_tags(controller, action)
resources = {}
for kind in module.REQUIRED_RESOURCE_KINDS:
    resources[kind] = {
        "id": "/resource/" + kind, "immutable_id": "immutable-" + kind,
        "etag": "etag-" + kind, "tags": dict(tags),
    }
resources["vm"]["power_state"] = "VM running"
resources["nic"]["attached_to"] = resources["vm"]["id"]
for kind in ("os-disk", "task-disk", "account-disk"):
    resources[kind]["attached_to"] = resources["vm"]["id"]
for kind in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
    resources[kind]["attached_to"] = resources["vm"]["id"]
for kind in ("monitor-extension", "bootstrap-command", "task-command"):
    resources[kind]["provisioning_state"] = "Succeeded"
resources["ttl-schedule"].update({"status": "Enabled", "deadline": "2300"})
for kind in ("global-reservation", "staging-request", "staging-result"):
    resources[kind].update({"digest": "f" * 64, "length": 1})
action["resources"] = {
    kind: {"id": value["id"], "immutable_id": value["immutable_id"]}
    for kind, value in resources.items()
}
worker = {"slot": 1, "resources": resources}
module.recorded_exact(action, worker)
for child in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
    changed = copy.deepcopy(worker)
    changed["resources"][child]["attached_to"] = "/foreign-vm"
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError as exc:
        assert "exact worker VM" in str(exc)
    else:
        raise AssertionError("foreign {} target accepted".format(child))
changed = copy.deepcopy(worker)
changed["resources"]["ttl-schedule"]["status"] = "Disabled"
try:
    module.recorded_exact(action, changed)
except module.ProviderError as exc:
    assert "TTL" in str(exc)
else:
    raise AssertionError("disabled TTL schedule accepted")
changed = copy.deepcopy(worker)
changed["resources"].pop("task-command")
try:
    module.recorded_exact(action, changed)
except module.ProviderError as exc:
    assert "task-command" in str(exc)
else:
    raise AssertionError("missing task Run Command accepted")
for kind in module.REQUIRED_RESOURCE_KINDS:
    changed = copy.deepcopy(worker)
    changed["resources"][kind]["immutable_id"] = "foreign"
    if kind in ("staging-request", "staging-result"):
        # Transport blobs rewrite on every execute; only their path is fenced.
        module.recorded_exact(action, changed)
        moved = copy.deepcopy(worker)
        moved["resources"][kind]["id"] = "/slot/1/elsewhere"
        try:
            module.recorded_exact(action, moved)
        except module.ProviderError:
            pass
        else:
            raise AssertionError("relocated {} blob path accepted".format(kind))
        continue
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError:
        pass
    else:
        raise AssertionError("foreign {} immutable identity accepted".format(kind))
for key in tags:
    changed = copy.deepcopy(worker)
    changed["resources"]["task-disk"]["tags"][key] = "foreign"
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError:
        pass
    else:
        raise AssertionError("foreign task-disk tag accepted: {}".format(key))

# Specialized validation demand and its durable reservation are exact shared
# capacity inputs; active-without-reservation and foreign reservation identities fail closed.
invocation = "azr-000000000001"
specialized_tags = {
    "workload": "firstmate", "deployment-generation": "dep", "cleanup-owner": "owner",
    "firstmate-role": "validation-shard", "invocation-binding": invocation,
    "selected-sku": "Standard_D4as_v6", "sku-family": "standardDav6Family",
}
specialized_vm = {
    "tags": specialized_tags, "powerState": "VM running",
    "hardwareProfile": {"vmSize": "Standard_D4as_v6"},
}
reservation_name = "id-fmtest-rsv-000000000001"
reservation_id = module.exact_id(
    controller, "Microsoft.ManagedIdentity", "userAssignedIdentities", reservation_name
)
reservation_tags = {
    "workload": "firstmate", "deployment-generation": "dep", "cleanup-owner": "owner",
    "firstmate-role": "runner-cost-reservation", "invocation-binding": invocation,
    "selected-sku": "Standard_D4as_v6", "sku-family": "standardDav6Family",
    "cost-admission-mode": "commissioning-bounded", "cell-ordinal": "3",
    "amount-microusd": "1000000", "cleanup-verified-at": "none",
    "fence-digest": "a" * 64, "reserved-at": "2026-01-01T00:00:00Z",
    "compute-deadline": "2026-01-02T00:00:00Z", "reservation-principal": "principal",
}
reservation = {
    "id": reservation_id, "location": "eastus",
    "properties": {"principalId": "principal"}, "tags": reservation_tags,
}
capacity, active_family = module.specialized_capacity_inventory(
    controller, [specialized_vm], [reservation]
)
assert capacity[0]["active"] is True and active_family["standardDav6Family"] == 4
# NO refusal for an active specialized VM without a reservation: nothing in this
# repo mints a runner-cost-reservation identity, so that requirement could never
# be met, and being global and fail-closed it refused every WORKER operation
# while ANOTHER lane had compute up.
capacity, no_ledger_family = module.specialized_capacity_inventory(
    controller, [specialized_vm], []
)
assert no_ledger_family["standardDav6Family"] == 4, no_ledger_family

# Both real producer shapes must pass. bin/fm-azure-runner.py defaults to
# ("none","0") for a standalone shard, while bin/fm-azure-validation.py launches
# one with a REAL parent and a real reserved count. Matching only the first shape
# was tried and left the outage live for every validation-cell run.
for parent, reserved in (("none", "0"), ("azv-0000000000ab", "40")):
    lane_vm = copy.deepcopy(specialized_vm)
    lane_vm["tags"]["invocation-binding"] = "azr-0000000000fe"
    lane_vm["tags"]["capacity-parent"] = parent
    lane_vm["tags"]["capacity-reservation-vcpus"] = reserved
    _, lane_family = module.specialized_capacity_inventory(controller, [lane_vm], [])
    assert lane_family["standardDav6Family"] == 4, (parent, reserved, lane_family)

# The guards that DO still fail closed are untouched: a foreign owner is still
# refused even though the reservation requirement is gone.
foreign = copy.deepcopy(reservation)
foreign["tags"]["cleanup-owner"] = "foreign"
try:
    module.specialized_capacity_inventory(controller, [], [foreign])
except module.ProviderError as exc:
    assert "foreign" in str(exc)
else:
    raise AssertionError("foreign specialized reservation was accepted")

# Azure child resources list as parent/child names; the slot parser must
# accept them, and generic four-vCPU-only validation must not reject the
# reviewed eight-vCPU control lane.
assert module.slot_from_name("vm-fmtest-wkr-01/AzureMonitorLinuxAgent", r"^vm-fmtest-wkr-") == 1
assert module.slot_from_name("vm-fmtest-wkr-07/execute", r"^vm-fmtest-wkr-") == 7
assert module.slot_from_name("vm-fmtest-wkr-1x", r"^vm-fmtest-wkr-") is None
control_invocation = "azr-000000000002"
control_vm = {
    "tags": {
        "workload": "firstmate", "deployment-generation": "dep", "cleanup-owner": "owner",
        "firstmate-role": "validation-cell", "invocation-binding": control_invocation,
        "selected-sku": "Standard_D8as_v6", "sku-family": "standardDav6Family",
    },
    "powerState": "VM running", "hardwareProfile": {"vmSize": "Standard_D8as_v6"},
}
control_reservation = copy.deepcopy(reservation)
control_reservation["id"] = module.exact_id(
    controller, "Microsoft.ManagedIdentity", "userAssignedIdentities", "id-fmtest-rsv-000000000002"
)
control_reservation["tags"] = dict(control_reservation["tags"])
control_reservation["tags"].update({
    "invocation-binding": control_invocation,
    "selected-sku": "Standard_D8as_v6", "sku-family": "standardDav6Family",
    "cost-admission-mode": "strict", "cell-ordinal": "none",
})
capacity, active_family = module.specialized_capacity_inventory(
    controller, [control_vm], [control_reservation]
)
assert capacity[0]["vcpus"] == 8 and active_family["standardDav6Family"] == 8
unreviewed_control = copy.deepcopy(control_vm)
unreviewed_control["tags"]["selected-sku"] = "Standard_D8as_v5"
unreviewed_control["hardwareProfile"]["vmSize"] = "Standard_D8as_v5"
try:
    module.specialized_capacity_inventory(controller, [unreviewed_control], [])
except module.ProviderError as exc:
    assert "malformed" in str(exc)
else:
    raise AssertionError("unreviewed eight-vCPU control SKU was accepted")

# An interrupted create (template children, no VM) replays the same landed
# deployment only under exact or absent bindings; foreign bindings refuse.
# A fresh module instance keeps these stubs out of the shared assertions.
partial_spec=importlib.util.spec_from_file_location("azure_provider_partial", sys.argv[1])
partial_module=importlib.util.module_from_spec(partial_spec); partial_spec.loader.exec_module(partial_module)
partial_calls=[]
partial_module.run_pilot_create=lambda controller, action: partial_calls.append("create")
partial_module.create_lifecycle_children=lambda controller, action: partial_calls.append("children")
partial_module.converge_create_tags=lambda controller, action: partial_calls.append("converge") or {"slot": 1, "resources": {}}
partial_action={"slot":1,"bindings":{"home_binding":"h"*64,"task":"task-a","task_generation":"g","assignment_generation":"asg-1","account_binding":"a"*64,"worktree_binding":"w"*64,"repository_binding":"r"*64,"repository_generation":"rg"},"sku":"Standard_D4as_v6","sku_family":"standardDav6Family","shared_admission_digest":"x","type":"create"}
partial_worker={"slot":1,"resources":{"nic":{"id":"/nic","immutable_id":"n","tags":{"home-binding":"h"*64,"task-binding":"task-a","invocation-binding":"asg-1"}},"task-disk":{"id":"/d","immutable_id":"d","tags":{}}}}
partial_module.inventory=lambda controller, include_metrics=True: {"workers":[partial_worker],"conflicts":[],"capacity_reservations":[],"metrics":{}}
partial_module.worker_by_slot=lambda snapshot, slot: partial_worker
partial_module.create_or_resume({"prefix":"fmtest"}, partial_action)
assert partial_calls==["create","children","converge"], partial_calls
partial_foreign=dict(partial_worker); partial_foreign["resources"]={"nic":{"id":"/nic","immutable_id":"n","tags":{"invocation-binding":"asg-OTHER"}}}
partial_module.worker_by_slot=lambda snapshot, slot: partial_foreign
try:
    partial_module.create_or_resume({"prefix":"fmtest"}, partial_action)
except partial_module.ProviderError as exc:
    assert "refuses to inherit" in str(exc)
else:
    raise AssertionError("foreign partial slot was inherited")

# A pre-convergence container has empty metadata; it inherits a same-slot
# exact-fleet sibling's tags (VM first) instead of classifying as foreign,
# while a bare orphan container keeps its emptiness and still refuses.
sibling_tags={"workload":"firstmate","deployment-generation":"dep","cleanup-owner":"owner"}
partial_workers={1:{"slot":1,"resources":{"nic":{"tags":dict(sibling_tags)}}}}
assert module.partial_container_metadata({}, 1, partial_workers) == sibling_tags
vm_workers={1:{"slot":1,"resources":{"nic":{"tags":{"workload":"nic"}},"vm":{"tags":dict(sibling_tags)}}}}
assert module.partial_container_metadata({}, 1, vm_workers) == sibling_tags
assert module.partial_container_metadata({}, 2, partial_workers) == {}
stamped={"workload":"firstmate","deployment-generation":"other","cleanup-owner":"owner"}
assert module.partial_container_metadata(dict(stamped), 1, partial_workers) == stamped

# Any untagged pre-convergence child (extension, run command, TTL) inherits
# the same sibling proof; a slot with no proven sibling yields emptiness.
assert module.slot_sibling_tags(partial_workers, 1) == sibling_tags
assert module.slot_sibling_tags(vm_workers, 1) == sibling_tags
assert module.slot_sibling_tags(partial_workers, 2) == {}

# Guest marker framing: only marker lines parse, the last one wins, and a
# malformed payload fails closed.
assert module.marker_payload("noise\nFM-X:{}\n", "FM-WORKER-RESULT:") is None
assert module.marker_payload(
    'junk\nFM-WORKER-RESULT:{"a":1}\nFM-WORKER-RESULT:{"a":2}\ntail', "FM-WORKER-RESULT:"
) == {"a": 2}
try:
    module.marker_payload("FM-WORKER-RESULT:{broken", "FM-WORKER-RESULT:")
except module.ProviderError as exc:
    assert "malformed" in str(exc)
else:
    raise AssertionError("malformed guest marker payload was accepted")

# Retail admission accepts one exact Linux on-demand primary meter and rejects
# Spot/Low Priority/Windows plus ambiguous eligible prices.
class PriceResponse:
    def __init__(self, value): self.value = value
    def __enter__(self): return self
    def __exit__(self, *_args): return False
    def read(self): return json.dumps(self.value).encode()
    def __iter__(self): return iter(())
def meter(price=0.25, **changes):
    value = {
        "armRegionName": "eastus", "armSkuName": "Standard_D4as_v6",
        "serviceName": "Virtual Machines", "serviceFamily": "Compute",
        "type": "Consumption", "unitOfMeasure": "1 Hour", "currencyCode": "USD",
        "productName": "Virtual Machines Dasv6 Series", "skuName": "D4as v6",
        "meterName": "D4as v6", "isPrimaryMeterRegion": True,
        "retailPrice": price, "unitPrice": price, "tierMinimumUnits": 0,
    }
    value.update(changes); return value
module.urllib.request.urlopen = lambda *_a, **_k: PriceResponse({"Items": [meter()]})
assert module.retail_rate("Standard_D4as_v6") == 0.25
module.urllib.request.urlopen = lambda *_a, **_k: PriceResponse({"Items": [meter(), meter(0.30)]})
assert module.retail_rate("Standard_D4as_v6") is None
module.urllib.request.urlopen = lambda *_a, **_k: PriceResponse({"Items": [meter(productName="Virtual Machines Dasv6 Series Spot")]})
assert module.retail_rate("Standard_D4as_v6") is None

# Metrics read authoritative actual cost before the forecast. A fresh,
# untrained forecast remains explicit without obscuring a readable actual.
cost_calls = []
original_cost_query = module.cost_query
original_cost_query_with_state = module.cost_query_with_state
original_az = module.az
original_retail_rate = module.retail_rate
module.cost_query = lambda _controller, forecast: cost_calls.append(("actual", forecast)) or 1.148
module.cost_query_with_state = lambda _controller, forecast: cost_calls.append(("forecast", forecast)) or (None, True)
module.az = lambda *_args, **_kwargs: ([], 0, "")
module.retail_rate = lambda _sku: 0.25
observed_metrics = module.metrics(controller, [], [], {})
assert cost_calls == [("actual", False), ("forecast", True)], cost_calls
assert observed_metrics["actual_usd"] == 1.148
assert observed_metrics["forecast_usd"] is None
assert observed_metrics["forecast_untrained"] is True
module.cost_query = original_cost_query
module.cost_query_with_state = original_cost_query_with_state
module.az = original_az
module.retail_rate = original_retail_rate

# Cost reads retry the exact Cost Management client-type 429 throttle with
# bounded short spacing; every other failure keeps single-attempt semantics.
class FakeCostTime:
    def __init__(self):
        self.now = 0.0
        self.sleeps = []
    def monotonic(self):
        return self.now
    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds
original_cost_time = module.time
throttle_stderr = '{"error":{"code":"429","message":"Too many requests. Please retry."}}'
cost_success = {"properties": {"columns": [{"name": "PreTaxCost"}, {"name": "Currency"}], "rows": [[1.75, "USD"]]}}
cost_attempts = []
def az_throttle_then_ok(_controller, args, check=True):
    cost_attempts.append(args)
    if len(cost_attempts) < 3:
        return (None, 1, throttle_stderr)
    return (dict(cost_success), 0, "")
fake_cost_time = FakeCostTime()
module.time = fake_cost_time
module.az = az_throttle_then_ok
throttled_value, throttled_untrained = module.cost_query_with_state(controller, False)
assert throttled_value == 1.75 and throttled_untrained is False, (throttled_value, throttled_untrained)
assert len(cost_attempts) == 3, cost_attempts
assert fake_cost_time.sleeps == [module.COST_THROTTLE_RETRY_SPACING_SECONDS] * 2, fake_cost_time.sleeps

cost_attempts = []
fake_cost_time = FakeCostTime()
module.time = fake_cost_time
module.az = lambda _c, args, check=True: cost_attempts.append(args) or (None, 1, throttle_stderr)
exhausted_value, exhausted_untrained = module.cost_query_with_state(controller, False)
assert exhausted_value is None and exhausted_untrained is False
expected_sleeps = module.COST_THROTTLE_RETRY_DEADLINE_SECONDS // module.COST_THROTTLE_RETRY_SPACING_SECONDS
assert len(cost_attempts) == expected_sleeps + 1, len(cost_attempts)
assert all(s == module.COST_THROTTLE_RETRY_SPACING_SECONDS for s in fake_cost_time.sleeps)

cost_attempts = []
fake_cost_time = FakeCostTime()
module.time = fake_cost_time
module.az = lambda _c, args, check=True: cost_attempts.append(args) or (None, 1, "ERROR: management token unavailable")
plain_value, plain_untrained = module.cost_query_with_state(controller, False)
assert plain_value is None and plain_untrained is False and len(cost_attempts) == 1
assert fake_cost_time.sleeps == []

cost_attempts = []
module.az = lambda _c, args, check=True: cost_attempts.append(args) or (None, 1, "(424) A valid forecast can not be created. There is no cost training data.")
untrained_value, untrained_flag = module.cost_query_with_state(controller, True)
assert untrained_value is None and untrained_flag is True and len(cost_attempts) == 1
module.time = original_cost_time
module.az = original_az

# Public IP relations are rejected while a private NIC is accepted.
nic = {
    "id": "/nic", "etag": "etag", "tags": tags,
    "properties": {"resourceGuid": "guid", "ipConfigurations": [{"properties": {}}]},
}
module.resource_record("nic", nic)
public = copy.deepcopy(nic)
public["properties"]["ipConfigurations"][0]["properties"]["publicIPAddress"] = {"id": "/public"}
try:
    module.resource_record("nic", public)
except module.ProviderError as exc:
    assert "public IP" in str(exc)
else:
    raise AssertionError("public worker NIC relation accepted")

# ETag-bearing resources delete with If-Match. ETag-less ARM kinds (Compute,
# MSI, DevTestLab reads supply none) re-read the exact resource and require
# the recorded immutable identity immediately before an exact-ID delete; a
# changed identity refuses. Role assignments keep their principal/role pair.
calls = []
current_disk = {"id": "/disk", "properties": {"uniqueId": "disk-guid"}}
def az_stub(controller_arg, args, check=False):
    calls.append(args)
    if args[0:2] == ["resource", "show"]:
        return (dict(current_disk), 0, "")
    return ({}, 0, "")
module.az = az_stub
module.conditional_delete(controller, "nic", {"id": "/nic", "etag": "etag-1", "immutable_id": "guid"})
assert calls[-1][0:3] == ["rest", "--method", "delete"] and "If-Match=etag-1" in calls[-1][-1]
module.conditional_delete(controller, "task-disk", {"id": "/disk", "etag": None, "immutable_id": "disk-guid"})
assert calls[-1][0:3] == ["rest", "--method", "delete"] and "--headers" not in calls[-1]
try:
    module.conditional_delete(controller, "task-disk", {"id": "/disk", "etag": None, "immutable_id": "other-guid"})
except module.ProviderError as exc:
    assert "immutable identity changed" in str(exc)
else:
    raise AssertionError("etag-less deletion accepted a changed immutable identity")
module.conditional_delete(controller, "role-assignment", {"id": "/role", "etag": None})
assert calls[-1][0:3] == ["rest", "--method", "delete"] and "--headers" not in calls[-1]

# Compute cleanup order deletes command children before VM and keeps TTL until
# VM absence plus NIC/disk detach are independently proven.
source = open(sys.argv[1], encoding="utf-8").read()
cleanup = source[source.index("def mutate_delete_compute"):source.index("def mutate_reset")]
assert cleanup.index('"task-command", "bootstrap-command", "monitor-extension", "vm"') < cleanup.index('conditional_delete(controller, "ttl-schedule", ttl)')
assert cleanup.index('wait_absent(controller, resource["id"])') < cleanup.index('conditional_delete(controller, "ttl-schedule", ttl)')

# Mutation idempotency rejects any changed action under a stale key.
unsigned = dict(action)
unsigned["type"] = "steer"
unsigned["request_digest"] = "5" * 64
unsigned["idempotency_key"] = hashlib.sha256(module.canonical_bytes(unsigned)).hexdigest()
tampered_create = dict(action)
tampered_create.update({"type": "create", "shared_admission_digest": "0" * 64})
try:
    module.run_pilot_create(controller, tampered_create)
except module.ProviderError as exc:
    assert "shared allocator" in str(exc)
else:
    raise AssertionError("singleton create accepted a forged shared-admission proof")

tampered = dict(unsigned)
tampered["request_digest"] = "6" * 64
try:
    module.mutate(controller, tampered)
except module.ProviderError as exc:
    assert "idempotency" in str(exc)
else:
    raise AssertionError("tampered provider action accepted")
PY
  pass "Azure provider rejects foreign worker identities, malformed runner reservations, public NICs, unfenced deletes, and stale action keys"
}

write_fixture_provider() {
  cat >"$1" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

import fcntl

path = Path(os.environ["FIXTURE_STATE"])
request = json.load(sys.stdin)
controller = request["controller"]

def barrier(action):
    # A real kernel rendezvous, not a sleep: arrival is an O_EXCL file named
    # by the idempotency key; release is a blocking FIFO read. It must not
    # perturb the action payload, which the key check below re-derives, and it
    # must run BEFORE the fixture state lock, or the first parked mutate would
    # hold the lock and the second could never arrive.
    barrier_dir = os.environ.get("FIXTURE_BARRIER_DIR")
    if not barrier_dir:
        return
    kinds = os.environ.get("FIXTURE_BARRIER_TYPES", "").split(",")
    if action.get("type") not in kinds:
        return
    arrived = Path(barrier_dir) / "arrived"
    arrived.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(arrived / action["idempotency_key"]), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    os.close(fd)
    with open(Path(barrier_dir) / "release", "r") as gate:
        gate.read(1)

if request["operation"] == "mutate":
    barrier(request["action"])
# The stub is not concurrency-safe without this: two concurrent mutates would
# lose one another's read-modify-write and fire the create assertion below
# spuriously, indistinguishable from a controller bug.
lock_handle = open(str(path) + ".lock", "a+")
fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
if path.exists():
    state = json.loads(path.read_text())
else:
    state = {
        "workers": {}, "seen": {}, "calls": [],
        "metrics": {"actual_usd": 100.0, "forecast_usd": 150.0},
    }

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def tags(action):
    bindings = action["bindings"]
    return {
        "workload": "firstmate", "firstmate-role": "worker",
        "deployment-generation": action["deployment_generation"], "cleanup-owner": action["owner"],
        "worker-slot": str(action["slot"]), "home-binding": bindings["home_binding"],
        "task-binding": bindings["task"], "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "account-binding": bindings["account_binding"], "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "agent-capacity": "one-task-scoped-crewmate", "nested-team": "forbidden",
        "secondmate-placement": "forbidden", "browser-profile": "forbidden",
    }

def resource(action, kind, serial=None):
    serial = serial or "{}-{}".format(action["cloud_generation"], action["idempotency_key"][:8])
    value = {
        "id": "/fixture/slot/{}/{}".format(action["slot"], kind),
        "immutable_id": "{}-{}".format(kind, serial), "etag": "etag-{}".format(serial),
        "tags": tags(action),
    }
    return value

def complete_worker(action, retained=None):
    resources = dict(retained or {})
    for kind in (
        "vm", "nic", "os-disk", "task-disk", "account-disk", "identity", "role-assignment",
        "state-container", "monitor-extension", "bootstrap-command", "task-command", "ttl-schedule",
        "global-reservation", "staging-request", "staging-result",
    ):
        if kind not in resources:
            resources[kind] = resource(action, kind)
    resources["vm"]["power_state"] = "VM running"
    resources["nic"]["attached_to"] = resources["vm"]["id"]
    for kind in ("os-disk", "task-disk", "account-disk"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    for kind in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    for kind in ("monitor-extension", "bootstrap-command", "task-command"):
        resources[kind]["provisioning_state"] = "Succeeded"
    resources["ttl-schedule"].update({"status": "Enabled", "deadline": "2300"})
    for kind in ("global-reservation", "staging-request", "staging-result"):
        resources[kind].update({"digest": "f" * 64, "length": 1})
    return {"slot": action["slot"], "resources": resources}

def save():
    path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")

if request["operation"] == "mutate":
    action = request["action"]
    key = action["idempotency_key"]
    # The REAL provider recomputes this hash over the whole action it received
    # and refuses a mismatch. A fixture that skips the check is more permissive
    # than the callee it stands in for, so it happily accepted an action whose
    # key was minted before its payload and outcome fields were added, while
    # bin/fm-azure-worker-provider.py refused every one of them.
    expected_key = hashlib.sha256(canonical(
        {name: value for name, value in action.items() if name != "idempotency_key"}
    )).hexdigest()
    if key != expected_key:
        sys.stderr.write(
            "FIXTURE PROVIDER REFUSED: idempotency key is not exact for a {} carrying {}\n".format(
                action.get("type"),
                sorted(n for n in action if n in ("payload_dir", "account_dir", "outcome_dir")),
            )
        )
        raise SystemExit(1)
    state["calls"].append({
        "type": action["type"], "slot": action["slot"], "key": key,
        "outcome_expected": bool((action.get("request") or {}).get("outcome_expected")),
        "outcome_dir": action.get("outcome_dir"),
    })
    if key in state["seen"]:
        result = state["seen"][key]
    else:
        slot = str(action["slot"])
        kind = action["type"]
        if kind == "create":
            assert slot not in state["workers"]
            worker = complete_worker(action)
            state["workers"][slot] = worker
            result = {"idempotency_key": key, "action": kind, "worker": worker}
        elif kind == "resume":
            old = state["workers"][slot]["resources"]
            retained = {name: old[name] for name in (
                "task-disk", "account-disk", "identity", "role-assignment", "state-container",
                "global-reservation", "staging-request", "staging-result",
            )}
            worker = complete_worker(action, retained=retained)
            state["workers"][slot] = worker
            result = {"idempotency_key": key, "action": kind, "worker": worker}
        elif kind == "deallocate":
            worker = state["workers"][slot]
            worker["resources"]["vm"]["power_state"] = "VM deallocated"
            result = {"idempotency_key": key, "action": kind, "worker": worker}
        elif kind == "delete-compute":
            worker = state["workers"][slot]
            for name in (
                "vm", "nic", "os-disk", "monitor-extension", "bootstrap-command",
                "task-command", "ttl-schedule",
            ):
                worker["resources"].pop(name, None)
            for name in ("task-disk", "account-disk"):
                worker["resources"][name]["attached_to"] = None
            result = {"idempotency_key": key, "action": kind, "worker": worker}
        elif kind == "reset":
            state["workers"].pop(slot)
            result = {"idempotency_key": key, "action": kind}
        elif kind == "execute":
            request_value = action["request"]
            execution = {
                "schema": "fm.worker-execution-result/v1",
                "request_digest": action["request_digest"],
                "task": request_value["task"], "task_generation": request_value["task_generation"],
                "assignment_generation": request_value["assignment_generation"],
                "cloud_instance_id": action["cloud_instance_id"],
                "repository_binding": request_value["repository_binding"],
                "repository_generation": request_value["repository_generation"],
                "exit_code": 0, "timed_out": False,
                "stdout_sha256": "a" * 64, "stderr_sha256": "b" * 64,
                "stdout_truncated": False, "stderr_truncated": False,
            }
            if request_value.get("outcome_expected") and not os.environ.get("FIXTURE_OMIT_OUTCOME"):
                execution.update({
                    "outcome_present": False, "outcome_error": "",
                    "outcome_commits": 0, "outcome_sha256": "", "outcome_bytes": 0,
                    "outcome_sink": "", "outcome_uncommitted_changes": False,
                })
            execution["streams_persisted"] = True
            execution["result_digest"] = hashlib.sha256(canonical(execution)).hexdigest()
            result = {"idempotency_key": key, "action": kind, "worker": state["workers"][slot], "execution": execution}
        elif kind == "steer":
            result = {"idempotency_key": key, "action": kind, "worker": state["workers"][slot]}
        else:
            raise AssertionError(kind)
        state["seen"][key] = result
    save()
else:
    active = sum(
        1 for worker in state["workers"].values()
        if "vm" in worker["resources"] and "deallocated" not in worker["resources"]["vm"].get("power_state", "").lower()
    )
    metrics = {
        "actual_usd": state["metrics"]["actual_usd"],
        "forecast_usd": state["metrics"]["forecast_usd"],
        "regional_limit_vcpus": 128, "regional_used_vcpus": 2 + 4 * active,
        "specialized_active_vcpus": 0, "specialized_active_by_family": {},
        "family_limit_vcpus": {}, "family_used_vcpus": {},
        "family_free_vcpus": {}, "sku_hourly_usd": {},
    }
    plan = {
        1:("Standard_D4as_v6","standardDav6Family"),2:("Standard_D4as_v6","standardDav6Family"),
        3:("Standard_D4as_v7","StandardDasv7Family"),4:("Standard_D4as_v7","StandardDasv7Family"),
        5:("Standard_D4s_v6","StandardDsv6Family"),6:("Standard_D4s_v6","StandardDsv6Family"),
        7:("Standard_D4ads_v7","StandardDadsv7Family"),8:("Standard_D4ads_v7","StandardDadsv7Family"),
        9:("Standard_D4ads_v6","standardDadv6Family"),10:("Standard_D4ads_v6","standardDadv6Family"),
        11:("Standard_E4as_v7","StandardEasv7Family"),12:("Standard_E4as_v7","StandardEasv7Family"),
        13:("Standard_E4as_v6","standardEav6Family"),14:("Standard_E4as_v6","standardEav6Family"),
        15:("Standard_D4ds_v6","StandardDdsv6Family"),16:("Standard_D4ds_v6","StandardDdsv6Family"),
    }
    for sku, family in plan.values():
        metrics["family_limit_vcpus"][family] = 10
        metrics["family_used_vcpus"][family] = 0
        metrics["family_free_vcpus"][family] = 10
        metrics["sku_hourly_usd"][sku] = 0.25
    inventory = {
        "schema": "fm.worker-provider-inventory/v1", "observed_at": "2026-01-01T00:00:00Z",
        "workers": [state["workers"][key] for key in sorted(state["workers"], key=int)],
        "capacity_reservations": state.get("capacity_reservations", []), "conflicts": [], "metrics": metrics,
    }
    result = inventory

response = {
    "schema": "fm.worker-provider-response/v1", "operation": request["operation"],
    "controller": controller,
}
response["result" if request["operation"] == "mutate" else "inventory"] = result
print(json.dumps(response, sort_keys=True, separators=(",", ":")))
PY
  chmod +x "$1"
}

end_to_end_lifecycle() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-lifecycle
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF

  python3 - "$CONTROLLER" "$WRAPPER" "$envfile" "$fixture" <<'PY' || fail "end-to-end lifecycle exercise failed"
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

controller_path, wrapper, envfile, fixture_path = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

def request(number):
    run(
        "request", "--task", "task-{}".format(number), "--task-generation", "gen-{}".format(number),
        "--home-binding", binding(1000 + number), "--account-binding", binding(2000 + number),
        "--worktree-binding", binding(3000 + number), "--repository-binding", binding(4000 + number),
        "--repository-generation", "repo-{}".format(number), "--owner-kind", "primary", "--eligible",
    )

def controller_state():
    return json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())

def fixture_state():
    path = Path(fixture_path)
    if not path.exists():
        return {"workers": {}, "seen": {}, "calls": [], "metrics": {}}
    return json.loads(path.read_text())

def release(number):
    state = controller_state()
    item = state["queue"]["task-{}@gen-{}".format(number, number)]
    worker = state["workers"][str(item["slot"])]
    proof = {
        "schema": "fm.worker-release/v2", "home_binding": worker["bindings"]["home_binding"],
        "task": "task-{}".format(number), "task_generation": "gen-{}".format(number),
        "assignment_generation": worker["assignment_generation"],
        "account_binding": worker["bindings"]["account_binding"],
        "worktree_binding": worker["bindings"]["worktree_binding"],
        "repository_binding": worker["bindings"]["repository_binding"],
        "repository_generation": worker["bindings"]["repository_generation"],
        "cloud_instance_id": worker["cloud_instance_id"], "resources": worker["resources"],
        "authorities": {},
    }
    for offset, authority in enumerate(("endpoint", "report", "landing", "account", "worktree"), 5):
        receipt = {
            "schema": "fm.worker-authority/v1", "authority": authority,
            "task": proof["task"], "task_generation": proof["task_generation"],
            "assignment_generation": proof["assignment_generation"], "verdict": "proved",
            "evidence_digest": binding(offset * 1000 + number),
        }
        receipt["receipt_digest"] = hashlib.sha256(
            json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        proof["authorities"][authority] = receipt
    canonical = json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()
    proof["proof_digest"] = hashlib.sha256(canonical).hexdigest()
    path = Path(env["FM_HOME"]) / "proof-{}.json".format(number)
    path.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
    run("release", "--task", proof["task"], "--task-generation", proof["task_generation"], "--proof-file", str(path))

# Start from zero and reach four parallel unique assignments.
status = json.loads(run("status", "--json").stdout)
assert status["queue_depth"] == 0 and status["desired_active_workers"] == 0
assert status["regional_admission_ceiling_vcpus"] == 128
assert status["author_plan_vcpus"] == 64
assert status["specialized_shape_vcpus"] == 40
assert status["shared_headroom_vcpus"] == 22
# A queued request that no worker ever took keeps counting as demand, so
# reconcile builds capacity for work that may already be finished elsewhere.
# Withdrawing it must remove that demand without touching capacity.
request(9)
assert "task-9@gen-9" in controller_state()["queue"]
plan = json.loads(run("reconcile", "--json").stdout)
assert [item for item in plan["actions"] if item["type"] == "create"], (
    "a queued request did not pull a worker, so the withdraw below proves nothing",
    plan["actions"],
)
refused = run("withdraw", "--task", "task-9", "--task-generation", "gen-9",
                  "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert refused.returncode != 0 and "--confirm-withdraw" in refused.stderr, refused.stderr
assert "task-9@gen-9" in controller_state()["queue"], "a refused withdraw dropped the entry anyway"
run("withdraw", "--task", "task-9", "--task-generation", "gen-9", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
withdrawn = controller_state()
assert "task-9@gen-9" not in withdrawn["queue"], withdrawn["queue"]
# NOT an assertion that workers is empty: at this point only a DRY reconcile
# has run, which rolls its provisional worker back and never persists, so
# `workers` is empty no matter what withdraw does. The real check runs below,
# once durable capacity exists.
assert "workers" in withdrawn
plan = json.loads(run("reconcile", "--json").stdout)
assert not [item for item in plan["actions"] if item["type"] == "create"], (
    "reconcile still plans a worker for a withdrawn request", plan["actions"],
)
assert run("withdraw", "--task", "task-9", "--task-generation", "gen-9",
           "--confirm-withdraw",
                       "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"], check=False).returncode != 0, "withdrawing twice succeeded"

for number in range(1, 5):
    request(number)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
# An entry with a worker behind it must go out through release, not withdraw:
# dropping it would strand that worker with no queue owner.
assigned_refusal = run("withdraw", "--task", "task-1", "--task-generation", "gen-1",
                       "--confirm-withdraw",
                       "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert assigned_refusal.returncode != 0, "withdraw accepted a task a worker owns"
assert "release it instead" in assigned_refusal.stderr, assigned_refusal.stderr
assert "task-1@gen-1" in controller_state()["queue"], "a refused withdraw dropped an assigned entry"


state = controller_state()
fixture = fixture_state()
assert len(state["workers"]) == 4 and len(fixture["workers"]) == 4
assert len({worker["bindings"]["account_binding"] for worker in state["workers"].values()}) == 4
assert len({worker["bindings"]["worktree_binding"] for worker in state["workers"].values()}) == 4
old_slot = state["queue"]["task-1@gen-1"]["slot"]
old_task_disk = state["workers"][str(old_slot)]["resources"]["task-disk"]["immutable_id"]
old_assignment = state["workers"][str(old_slot)]["assignment_generation"]

# The private one-task execution path returns an exact result and replays the
# same request from durable state without a second provider execution.
execution = json.loads(run(
    "execute", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", old_assignment, "--wall-seconds", "60",
    "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
    "--", "/usr/bin/true",
).stdout)
assert execution["schema"] == "fm.worker-execution-result/v1" and execution["exit_code"] == 0
call_count = len(fixture_state()["calls"])
repeat = json.loads(run(
    "execute", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", old_assignment, "--wall-seconds", "60",
    "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
    "--", "/usr/bin/true",
).stdout)
assert repeat == execution and len(fixture_state()["calls"]) == call_count

# Landing v1 arming: an outcome directory makes outcome_expected part of the
# digest-bound request, is refused without a staged repository, and is refused
# outright when the worker answers with no outcome disposition at all.
staging = Path(tempfile.mkdtemp(prefix="fm-outcome-arming-"))
payload_dir = staging / "payload"
account_dir = staging / "account"
outcome_dir = staging / "outcome"
for directory in (payload_dir, account_dir, outcome_dir):
    directory.mkdir()
(payload_dir / "repo.bundle").write_bytes(b"bundle-fixture")
(payload_dir / "brief.md").write_text("brief\n")
(account_dir / "auth.json").write_text("{}\n")


def armed_execute(*extra, overrides=None, command="/usr/bin/true"):
    call_env = dict(env)
    call_env.update(overrides or {})
    arguments = [
        "execute", "--task", "task-2", "--task-generation", "gen-2",
        "--assignment-generation", controller_state()["workers"][
            str(controller_state()["queue"]["task-2@gen-2"]["slot"])
        ]["assignment_generation"],
        "--wall-seconds", "60", *extra,
        "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
        "--", command,
    ]
    return subprocess.run(
        [wrapper] + arguments, env=call_env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )

refused = armed_execute("--outcome-dir", str(outcome_dir))
assert refused.returncode != 0 and "staged repository" in refused.stderr, refused.stderr
skewed = armed_execute(
    "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
    "--outcome-dir", str(outcome_dir), overrides={"FIXTURE_OMIT_OUTCOME": "1"},
    command="/bin/echo",
)
assert skewed.returncode != 0 and "no outcome disposition" in skewed.stderr, skewed.stderr

# The skewed execute left a durable claim, and its apply refuses
# deterministically (the provider result is final under key-idempotency), so
# the slot is deliberately wedged: a different execute refuses instead of
# blind-overwriting the claim, which is the double-run defect this discipline
# closes. The sanctioned exit is abandon-claim, which replays the mutation
# itself, proves the result binds the exact key, records the refusal with the
# result digest, and only then clears the claim.
skew_state = controller_state()
skew_slot = str(skew_state["queue"]["task-2@gen-2"]["slot"])
skew_claim = skew_state["pending_actions"][skew_slot]
blocked = armed_execute(
    "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
    "--outcome-dir", str(outcome_dir),
)
assert blocked.returncode != 0 and "still has an unapplied execute action" in blocked.stderr, blocked.stderr
refused_abandon = run("abandon-claim", "--slot", skew_slot, "--idempotency-key", "f" * 64,
                      "--confirm-abandon", "--confirm-subscription",
                      env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert refused_abandon.returncode != 0 and "different claim" in refused_abandon.stderr, refused_abandon.stderr
run("abandon-claim", "--slot", skew_slot, "--idempotency-key", skew_claim["idempotency_key"],
    "--confirm-abandon", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
after_abandon = controller_state()
assert skew_slot not in after_abandon["pending_actions"], after_abandon["pending_actions"]
assert any("claim abandoned by operator" in str(entry.get("note", ""))
           for entry in after_abandon["cleanup_refusals"]), after_abandon["cleanup_refusals"]
armed = armed_execute(
    "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
    "--outcome-dir", str(outcome_dir),
)
assert armed.returncode == 0, armed.stderr
armed_result = json.loads(armed.stdout)
assert armed_result["outcome_present"] is False, armed_result
armed_action = [
    entry for entry in fixture_state()["calls"] if entry["type"] == "execute"
][-1]
assert armed_action["outcome_expected"] is True, armed_action
assert armed_action["outcome_dir"] == str(outcome_dir.resolve()), armed_action

# A waiting task can use the slot only after deallocate, disposable deletion,
# complete reset, and a new assignment generation.
release(1)
request(5)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
fixture = fixture_state()
new_item = state["queue"]["task-5@gen-5"]
assert new_item["slot"] == old_slot
new_worker = state["workers"][str(old_slot)]
assert new_worker["assignment_generation"] != old_assignment
assert new_worker["resources"]["task-disk"]["immutable_id"] != old_task_disk
actions = [entry["type"] for entry in fixture["calls"]]
sequence = actions[-4:]
assert sequence == ["deallocate", "delete-compute", "reset", "create"], sequence

# Drain every active task and prove queue/compute/disposable capacity reach zero.
for number in (2, 3, 4, 5):
    release(number)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
fixture = fixture_state()
assert not state["workers"] and not fixture["workers"]
status = json.loads(run("status", "--live", "--json").stdout)
assert status["queue_depth"] == 0 and status["desired_active_workers"] == 0 and status["actual_active_workers"] == 0

# A missing VM is retained, never treated as safe or complete, and resumes only
# with the exact repository/task generation while keeping both dirty disks.
request(6)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
slot = state["queue"]["task-6@gen-6"]["slot"]
old_task = state["workers"][str(slot)]["resources"]["task-disk"]["immutable_id"]
old_account = state["workers"][str(slot)]["resources"]["account-disk"]["immutable_id"]
fixture = fixture_state()
for kind in ("vm", "nic", "os-disk"):
    fixture["workers"][str(slot)]["resources"].pop(kind)
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")))
status = json.loads(run("status", "--live", "--json").stdout)
assert status["classification_counts"]["retained-for-investigation"] == 1
wrong = run(
    "resume", "--task", "task-6", "--task-generation", "gen-6", "--repository-binding", binding(9999),
    "--confirm-resume", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"], check=False,
)
assert wrong.returncode == 2 and "repository/task generation" in wrong.stderr
run(
    "resume", "--task", "task-6", "--task-generation", "gen-6", "--repository-binding", binding(4006),
    "--confirm-resume", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
)
state = controller_state()
worker = state["workers"][str(slot)]
assert worker["resources"]["task-disk"]["immutable_id"] == old_task
assert worker["resources"]["account-disk"]["immutable_id"] == old_account
assert worker["cloud_generation"] == 2

# Cost pressure blocks a new discretionary launch but does not terminate the
# resumed active task.
request(7)
fixture = fixture_state()
fixture["metrics"] = {"actual_usd": 1499.0, "forecast_usd": 1499.0}
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")))
result = json.loads(run("reconcile", "--json").stdout)
assert result["actions"][0]["type"] == "admission-refused"
assert result["status"]["actual_active_workers"] == 1
assert len(fixture_state()["workers"]) == 1

# Capacity is untouched, checked where there IS capacity to touch.
capacity_before = controller_state()["workers"]
assert capacity_before, "no durable workers exist, so the capacity check below is vacuous"
request(10)
run("withdraw", "--task", "task-10", "--task-generation", "gen-10", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
after_withdraw = controller_state()
assert after_withdraw["workers"] == capacity_before, (
    "withdraw changed durable capacity", capacity_before, after_withdraw["workers"],
)
assert "task-10@gen-10" not in after_withdraw["queue"], after_withdraw["queue"]

# A pending provider action names its queue owner. Dropping the entry makes the
# next reconcile replay that action, fail to find the owner, and raise forever,
# because the pending action never clears. One stale entry would take the whole
# fleet's convergence with it.
request(11)
pending_state = controller_state()
# The claims must be REAL minted actions: verify_state re-derives the
# idempotency key from the stored bytes, so a hand-typed "f"*64 claim now
# refuses at load, and a guard tested through an unloadable file tests
# nothing. Two entries prove the guard fans out over the whole map, not just
# its first entry.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location("controller_mod", controller_path)
_cmod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_cmod)
_menv = {"deployment_generation": "dep-one", "owner": "owner"}
def _mint(slot, task):
    worker = {
        "slot": slot, "sku": "sku", "sku_family": "fam", "cloud_generation": 1,
        "cloud_instance_id": None, "reservation_usd": 1.0, "resources": {},
        "bindings": {"task": task, "task_generation": "gen-11" if task == "task-11" else "gen-x"},
    }
    return _cmod.make_action(_menv, "create", worker=worker,
                             item={"task": task, "task_generation": worker["bindings"]["task_generation"]})
pending_state["pending_actions"] = {
    "3": _mint(3, "task-unrelated"),
    "9": _mint(9, "task-11"),
}
controller_file = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"
pre_block = controller_file.read_text()
controller_file.write_text(json.dumps(pending_state, sort_keys=True, separators=(",", ":")))
pending_refusal = run("withdraw", "--task", "task-11", "--task-generation", "gen-11",
                      "--confirm-withdraw", "--confirm-subscription",
                      env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert pending_refusal.returncode != 0, "withdraw dropped an entry a pending action names"
assert "still names" in pending_refusal.stderr, pending_refusal.stderr
assert "slot 9" in pending_refusal.stderr, (
    "the guard did not fan out past the first map entry", pending_refusal.stderr)
assert "task-11@gen-11" in controller_state()["queue"], "the refused entry was dropped anyway"
controller_file.write_text(pre_block)
run("withdraw", "--task", "task-11", "--task-generation", "gen-11", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])

# `assigning` is persisted before the provider call and, behind a slow create,
# can hold for hours. It still counts as demand, so the refusal must not tell
# the operator it is "past the queue", and release cannot take it either.
request(14)
assigning_state = controller_state()
assigning_state["queue"]["task-14@gen-14"]["status"] = "assigning"
controller_path = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"
controller_path.write_text(json.dumps(assigning_state, sort_keys=True, separators=(",", ":")))
assigning_refusal = run("withdraw", "--task", "task-14", "--task-generation", "gen-14",
                        "--confirm-withdraw", "--confirm-subscription",
                        env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert assigning_refusal.returncode != 0, "withdraw accepted an assigning entry"
assert "in flight" in assigning_refusal.stderr, assigning_refusal.stderr
assert "past the queue" not in assigning_refusal.stderr, (
    "an assigning entry still counts as demand, so calling it past the queue is false",
    assigning_refusal.stderr,
)
assert "task-14@gen-14" in controller_state()["queue"], "the refused entry was dropped anyway"

# A wrong subscription must refuse, like every other mutating subcommand.
request(12)
wrong_subscription = run("withdraw", "--task", "task-12", "--task-generation", "gen-12",
                         "--confirm-withdraw", "--confirm-subscription",
                         "00000000-0000-0000-0000-00000000dead", check=False)
assert wrong_subscription.returncode != 0, "withdraw accepted a foreign subscription"
assert "--confirm-subscription" in wrong_subscription.stderr, wrong_subscription.stderr
assert "task-12@gen-12" in controller_state()["queue"], "the refused entry was dropped anyway"

# A withdrawn request leaves no owner for the per-task cloud state bin/fm-spawn.sh
# staged, and that includes a PLAINTEXT provider credential. Teardown never runs
# for a task that never got a worker, so withdraw has to be the owner.
cloud_account = Path(env["FM_HOME"]) / "state" / "task-12.cloud-account"
cloud_account.mkdir(parents=True, exist_ok=True)
credential = cloud_account / "auth.json"
credential.write_text('{"staged": "credential"}')
entrypoint = Path(env["FM_HOME"]) / "state" / "task-12.cloud-entrypoint"
entrypoint.write_text("launch\n")
run("withdraw", "--task", "task-12", "--task-generation", "gen-12", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
assert "task-12@gen-12" not in controller_state()["queue"]
assert not credential.exists(), "withdraw left the staged provider credential behind"
assert not cloud_account.exists(), "withdraw left the cloud-account directory behind"
assert not entrypoint.exists(), "withdraw left the convergence entrypoint behind"

# Cleanup must be bound to a withdrawal that actually happened. `--help` exits
# 0 without withdrawing, and an exit-code gate therefore destroyed a LIVE
# task's staged credential, payload and returned result.
live_account = Path(env["FM_HOME"]) / "state" / "task-1.cloud-account"
live_account.mkdir(parents=True, exist_ok=True)
live_credential = live_account / "auth.json"
live_credential.write_text('{"staged": "live"}')
live_result = Path(env["FM_HOME"]) / "state" / "task-1.worker-result.json"
live_result.write_text('{"result": "returned"}')
run("withdraw", "--task", "task-1", "--help", check=False)
assert live_credential.exists(), "withdraw --help destroyed a live task's provider credential"
assert live_result.exists(), "withdraw --help destroyed a live task's returned result"
assert "task-1@gen-1" in controller_state()["queue"], "withdraw --help dropped a live entry"

# A REFUSED withdraw must leave the task's cloud state alone too.
refused_live = run("withdraw", "--task", "task-1", "--task-generation", "gen-1",
                   "--confirm-withdraw", "--confirm-subscription",
                   env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
assert refused_live.returncode != 0, "withdraw accepted an assigned task"
assert live_credential.exists(), "a refused withdraw destroyed the task's provider credential"
assert live_result.exists(), "a refused withdraw destroyed the task's returned result"
live_credential.unlink()
live_result.unlink()

# The --task=<value> form parses fine, so cleanup must work there too; keying
# off argv missed it and silently left the credential on disk.
request(13)
equals_account = Path(env["FM_HOME"]) / "state" / "task-13.cloud-account"
equals_account.mkdir(parents=True, exist_ok=True)
equals_credential = equals_account / "auth.json"
equals_credential.write_text('{"staged": "credential"}')
run("withdraw", "--task=task-13", "--task-generation=gen-13", "--confirm-withdraw",
    "--confirm-subscription={}".format(env["FM_AZURE_SUBSCRIPTION_ID"]))
assert "task-13@gen-13" not in controller_state()["queue"]
assert not equals_credential.exists(), (
    "the --task=<value> form withdrew the entry but left the staged credential behind"
)
PY
  pass "zero-to-zero flow executes privately, replays idempotently, resets before reuse, resumes dirty disks, and preserves active work under budget refusal"
}

shared_specialized_cli() {
  local tmp provider fixture home fence receipt out state_file
  fm_test_tmproot_into tmp fm-shared-specialized
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  fence=$(printf reservation-fence | shasum -a 256 | awk '{print $1}')
  receipt=$(printf cleanup-proof | shasum -a 256 | awk '{print $1}')
  out=$(env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve \
      --reservation-id azr-123456789abc \
      --fence-binding "$fence" \
      --role validation \
      --sku Standard_D4as_v7 \
      --sku-family StandardDasv7Family \
      --vcpus 4 \
      --amount-usd 25 \
      --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "specialized capacity reservation did not admit"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "reserved"
assert value["actual_usd"] == 100.0 and value["forecast_usd"] == 150.0
PY
  state_file="$home/state/azure-workers/controller.json"
  # Repeating the same exact reservation must re-run current telemetry/capacity
  # admission without counting itself twice or silently trusting stale success.
  repeat=$(env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve \
      --reservation-id azr-123456789abc \
      --fence-binding "$fence" \
      --role validation \
      --sku Standard_D4as_v7 \
      --sku-family StandardDasv7Family \
      --vcpus 4 \
      --amount-usd 25 \
      --confirm-subscription "$SUB")
  python3 - "$repeat" <<'PY' || fail "exact specialized reservation retry was not idempotent"
import json
import sys
assert json.loads(sys.argv[1])["status"] == "reserved"
PY
  python3 - "$state_file" <<'PY' || fail "specialized capacity reservation was not durable"
import json
import sys
state = json.load(open(sys.argv[1]))
item = state["capacity_reservations"]["azr-123456789abc"]
assert item["status"] == "reserved" and item["sku_family"] == "StandardDasv7Family"
PY

  # A second exact-family reservation stays queued when observed plus reserved
  # would exceed the 10-vCPU family limit.
  out=$(env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve \
      --reservation-id azr-abcdef123456 \
      --fence-binding "$(printf second-fence | shasum -a 256 | awk '{print $1}')" \
      --role review \
      --sku Standard_D4as_v7 \
      --sku-family StandardDasv7Family \
      --vcpus 4 \
      --amount-usd 25 \
      --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "shared specialized refusal result malformed"
import json
import sys
value = json.loads(sys.argv[1])
# The fixture has 10 free and one prior 4-vCPU local reservation, so this exact
# second request still fits. A third proves the observed-plus-reserved refusal.
assert value["status"] == "reserved"
PY
  out=$(env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve \
      --reservation-id azr-fedcba654321 \
      --fence-binding "$(printf third-fence | shasum -a 256 | awk '{print $1}')" \
      --role browser \
      --sku Standard_D4as_v7 \
      --sku-family StandardDasv7Family \
      --vcpus 4 \
      --amount-usd 25 \
      --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "shared specialized family refusal did not queue"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "queued" and "family" in value["reason"]
PY

  env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-release \
      --reservation-id azr-123456789abc \
      --fence-binding "$fence" \
      --cleanup-receipt "$receipt" \
      --confirm-subscription "$SUB" >/dev/null
  python3 - "$state_file" <<'PY' || fail "specialized capacity release was not fenced"
import json
import sys
state = json.load(open(sys.argv[1]))
assert state["capacity_reservations"]["azr-123456789abc"]["status"] == "released"
assert state["capacity_reservations"]["azr-abcdef123456"]["status"] == "reserved"
assert state["capacity_reservations"]["azr-fedcba654321"]["status"] == "queued"
PY
  pass "specialized CLI durably reserves, queues exact-family excess, and releases only exact fenced capacity"
}

shared_shape_cli() {
  local tmp provider fixture home fence out state_file
  fm_test_tmproot_into tmp fm-shared-shape
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  fence=$(printf shape-fence | shasum -a 256 | awk '{print $1}')
  state_file="$home/state/azure-workers/controller.json"
  run_shape() {
    env \
      FM_HOME="$home" \
      FM_AZURE_SUBSCRIPTION_ID="$SUB" \
      FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
      FIXTURE_STATE="$fixture" \
      "$WRAPPER" "$@"
  }

  # A complete shape beyond the 40-vCPU specialized envelope refuses before
  # any durable write.
  if run_shape capacity-reserve-shape \
      --shape-id shape-oversized --fence-binding "$fence" \
      --constituent "reservation-id=azr-ovc000000001,role=validation,sku=Standard_D8as_v6,sku-family=standardDav6Family,vcpus=8,amount-usd=25" \
      --constituent "reservation-id=azr-ovc000000002,role=validation,sku=Standard_D8as_v7,sku-family=StandardDasv7Family,vcpus=8,amount-usd=25" \
      --constituent "reservation-id=azr-ovc000000003,role=validation,sku=Standard_D8s_v6,sku-family=StandardDsv6Family,vcpus=8,amount-usd=25" \
      --constituent "reservation-id=azr-ovc000000004,role=validation,sku=Standard_D8ads_v7,sku-family=StandardDadsv7Family,vcpus=8,amount-usd=25" \
      --constituent "reservation-id=azr-ovc000000005,role=validation,sku=Standard_D8ds_v6,sku-family=StandardDdsv6Family,vcpus=8,amount-usd=25" \
      --constituent "reservation-id=azr-ovc000000006,role=validation,sku=Standard_D4as_v6,sku-family=standardDav6Family,vcpus=4,amount-usd=25" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "44-vCPU shape bypassed the 40-vCPU specialized envelope"
  fi

  # An unreviewed eight-vCPU control SKU refuses.
  if run_shape capacity-reserve-shape \
      --shape-id shape-unreviewed --fence-binding "$fence" \
      --constituent "reservation-id=azr-bad000000001,role=validation,sku=Standard_D8as_v5,sku-family=standardDASv5Family,vcpus=8,amount-usd=25" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "unreviewed eight-vCPU control SKU was accepted"
  fi

  # All-or-nothing: one constituent overbooks its exact 10-vCPU family, so the
  # complete shape stays queued even though the second constituent fits alone.
  out=$(run_shape capacity-reserve-shape \
    --shape-id shape-conflict --fence-binding "$fence" \
    --constituent "reservation-id=azr-cfa000000001,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25" \
    --constituent "reservation-id=azr-cfa000000002,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25" \
    --constituent "reservation-id=azr-cfa000000003,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25" \
    --constituent "reservation-id=azr-cfb000000001,role=validation,sku=Standard_D4ads_v6,sku-family=standardDadv6Family,vcpus=4,amount-usd=25" \
    --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "family-conflicting shape was not atomically queued"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "queued" and "family" in value["reason"]
assert all(item["status"] == "queued" for item in value["constituents"])
PY
  # Positive control: the fitting constituent's family genuinely had room, so
  # the refusal above was the atomic shape gate rather than family pressure.
  out=$(run_shape capacity-reserve \
    --reservation-id azr-posctl000001 --fence-binding "$fence" \
    --role validation --sku Standard_D4ads_v6 --sku-family standardDadv6Family \
    --vcpus 4 --amount-usd 25 --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "positive-control single reservation did not admit"
import json
import sys
assert json.loads(sys.argv[1])["status"] == "reserved"
PY
  run_shape capacity-release \
    --reservation-id azr-posctl000001 --fence-binding "$fence" \
    --cleanup-receipt "$(printf posctl-cleanup | shasum -a 256 | awk '{print $1}')" \
    --confirm-subscription "$SUB" >/dev/null

  python3 - "$fixture" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text()) if path.exists() else {
    "workers": {}, "seen": {}, "calls": [],
    "metrics": {"actual_usd": 100.0, "forecast_usd": 200.0},
}
state["capacity_reservations"] = [{
    "reservation_id": "azr-cfa000000001", "role": "specialized",
    "sku": "Standard_D4as_v7", "sku_family": "StandardDasv7Family",
    "vcpus": 4, "amount_usd": 25, "active": True,
}]
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY
  if run_shape capacity-release \
      --reservation-id azr-cfa000000001 --fence-binding "$fence" \
      --cleanup-receipt "$(printf live-cleanup | shasum -a 256 | awk '{print $1}')" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "provider-observed live specialized compute was released"
  fi
  python3 - "$fixture" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state["capacity_reservations"][0]["active"] = False
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY
  run_shape capacity-release \
    --reservation-id azr-cfa000000001 --fence-binding "$fence" \
    --cleanup-receipt "$(printf absent-cleanup | shasum -a 256 | awk '{print $1}')" \
    --confirm-subscription "$SUB" >/dev/null
  python3 - "$fixture" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state["capacity_reservations"] = "unreadable"
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY
  if run_shape capacity-release \
      --reservation-id azr-cfb000000001 --fence-binding "$fence" \
      --cleanup-receipt "$(printf unreadable-cleanup | shasum -a 256 | awk '{print $1}')" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "unreadable provider inventory allowed specialized release"
  fi
  python3 - "$state_file" "$fixture" <<'PY' || fail "failed release changed durable reservation state"
import json
import sys
from pathlib import Path
controller = json.loads(Path(sys.argv[1]).read_text())
assert controller["capacity_reservations"]["azr-cfb000000001"]["status"] == "queued"
path = Path(sys.argv[2])
state = json.loads(path.read_text())
state["capacity_reservations"] = []
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY

  # The complete validation-heavy shape admits atomically: one reviewed
  # eight-vCPU control cell plus eight four-vCPU shards across exact families.
  shape_args=(
    --shape-id shape-accept --fence-binding "$fence"
    --constituent "reservation-id=azr-ctl000000001,role=validation,sku=Standard_D8as_v6,sku-family=standardDav6Family,vcpus=8,amount-usd=50"
    --constituent "reservation-id=azr-shd000000001,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000002,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000003,role=validation,sku=Standard_D4s_v6,sku-family=StandardDsv6Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000004,role=validation,sku=Standard_D4s_v6,sku-family=StandardDsv6Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000005,role=validation,sku=Standard_D4ads_v7,sku-family=StandardDadsv7Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000006,role=validation,sku=Standard_D4ads_v7,sku-family=StandardDadsv7Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000007,role=validation,sku=Standard_E4as_v6,sku-family=standardEav6Family,vcpus=4,amount-usd=25"
    --constituent "reservation-id=azr-shd000000008,role=validation,sku=Standard_E4as_v6,sku-family=standardEav6Family,vcpus=4,amount-usd=25"
    --confirm-subscription "$SUB"
  )
  out=$(run_shape capacity-reserve-shape "${shape_args[@]}")
  python3 - "$out" <<'PY' || fail "complete 40-vCPU shape did not admit atomically"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "reserved"
assert len(value["constituents"]) == 9
assert all(item["status"] == "reserved" for item in value["constituents"])
assert sum(item["vcpus"] for item in value["constituents"]) == 40
PY
  python3 - "$state_file" <<'PY' || fail "shape constituents were not durable"
import json
import sys
state = json.load(open(sys.argv[1]))
control = state["capacity_reservations"]["azr-ctl000000001"]
assert control["status"] == "reserved" and control["vcpus"] == 8
assert control["shape_id"] == "shape-accept"
assert state["capacity_reservations"]["azr-shd000000008"]["status"] == "reserved"
PY

  # Repeating the exact shape is idempotent and never demotes reserved
  # constituents.
  out=$(run_shape capacity-reserve-shape "${shape_args[@]}")
  python3 - "$out" <<'PY' || fail "exact shape retry was not idempotent"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "reserved"
assert all(item["status"] == "reserved" for item in value["constituents"])
PY

  # Child lineage: a runner re-admitting one exact constituent id must stay
  # reserved without double-counting the shape's own capacity, and its exact
  # first-day bound may come in at or below the parent's cushioned amount.
  out=$(run_shape capacity-reserve \
    --reservation-id azr-shd000000001 --fence-binding "$fence" \
    --role validation --sku Standard_D4as_v7 --sku-family StandardDasv7Family \
    --vcpus 4 --amount-usd 25 --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "child re-admission of a shape constituent failed"
import json
import sys
assert json.loads(sys.argv[1])["status"] == "reserved"
PY
  out=$(run_shape capacity-reserve \
    --reservation-id azr-shd000000001 --fence-binding "$fence" \
    --role validation --sku Standard_D4as_v7 --sku-family StandardDasv7Family \
    --vcpus 4 --amount-usd 18.5 --confirm-subscription "$SUB")
  python3 - "$out" <<'PY' || fail "child exact bound below the parent cushion was refused"
import json
import sys
assert json.loads(sys.argv[1])["status"] == "reserved"
PY
  if run_shape capacity-reserve \
      --reservation-id azr-shd000000001 --fence-binding "$fence" \
      --role validation --sku Standard_D4as_v7 --sku-family StandardDasv7Family \
      --vcpus 4 --amount-usd 26 --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "child bound above the parent cushion was accepted"
  fi

  # A changed identity for an existing constituent refuses.
  if run_shape capacity-reserve-shape \
      --shape-id shape-accept --fence-binding "$fence" \
      --constituent "reservation-id=azr-ctl000000001,role=review,sku=Standard_D8as_v6,sku-family=standardDav6Family,vcpus=8,amount-usd=50" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "conflicting shape constituent identity was accepted"
  fi

  # Budget pressure queues an additional shape without touching reserved work.
  python3 - "$fixture" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
if path.exists():
    state = json.loads(path.read_text())
else:
    state = {"workers": {}, "seen": {}, "calls": []}
state["metrics"] = {"actual_usd": 1499.0, "forecast_usd": 1499.0}
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY
  release_receipt=$(printf shape-cleanup | shasum -a 256 | awk '{print $1}')
  run_shape capacity-release \
    --reservation-id azr-shd000000008 --fence-binding "$fence" \
    --cleanup-receipt "$release_receipt" --confirm-subscription "$SUB" >/dev/null
  out=$(run_shape capacity-reserve-shape \
    --shape-id shape-budget --fence-binding "$fence" \
    --constituent "reservation-id=azr-bgt000000001,role=review,sku=Standard_E4as_v6,sku-family=standardEav6Family,vcpus=4,amount-usd=25" \
    --confirm-subscription "$SUB")
  python3 - "$out" "$state_file" <<'PY' || fail "budget pressure did not queue the new shape"
import json
import sys
value = json.loads(sys.argv[1])
assert value["status"] == "queued" and "limit" in value["reason"]
state = json.load(open(sys.argv[2]))
assert state["capacity_reservations"]["azr-ctl000000001"]["status"] == "reserved"
assert state["capacity_reservations"]["azr-shd000000008"]["status"] == "released"
PY
  if run_shape capacity-reserve-shape \
      --shape-id shape-required --fence-binding "$fence" \
      --constituent "reservation-id=azr-req000000001,role=review,sku=Standard_E4as_v6,sku-family=standardEav6Family,vcpus=4,amount-usd=25" \
      --required --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "capacity-reserve-shape still accepted the cost-admission bypass"
  fi

  # A released constituent identity can never re-enter a shape.
  if run_shape capacity-reserve-shape \
      --shape-id shape-reuse --fence-binding "$fence" \
      --constituent "reservation-id=azr-shd000000008,role=validation,sku=Standard_E4as_v6,sku-family=standardEav6Family,vcpus=4,amount-usd=25" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "released constituent identity was reused in a new shape"
  fi
  pass "complete specialized shapes admit atomically, queue on family or budget pressure, and never demote or reuse exact reservations"
}

landing_authority_refresh() {
  local tmp remote seed checkout
  fm_test_tmproot_into tmp fm-worker-landing-authority
  remote="$tmp/origin.git"
  seed="$tmp/seed"
  checkout="$tmp/checkout"
  git init --quiet --bare "$remote"
  git -C "$remote" symbolic-ref HEAD refs/heads/main
  git -C "$remote" config receive.denyDeleteCurrent ignore
  git init --quiet -b main "$seed"
  git -C "$seed" config user.name Test
  git -C "$seed" config user.email test@example.invalid
  printf 'landed\n' >"$seed/file"
  git -C "$seed" add file
  git -C "$seed" commit --quiet -m landed
  git -C "$seed" remote add origin "$remote"
  git -C "$seed" push --quiet -u origin main
  git clone --quiet "$remote" "$checkout"
  python3 - "$AUTHORITY" "$checkout" <<'PY' || fail "fresh origin branch did not prove landing"
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
head = module.git(Path(sys.argv[2]), "rev-parse", "HEAD")
assert b"refs/remotes/origin/main" in module.landing_evidence(Path(sys.argv[2]), head)
try:
    module.landing_evidence(Path(sys.argv[2]), "0" * 40)
except module.AuthorityError as exc:
    assert "descend" in str(exc)
else:
    raise AssertionError("landing accepted a foreign repository generation lineage")
PY
  git -C "$seed" push --quiet origin --delete main
  if python3 - "$AUTHORITY" "$checkout" <<'PY'
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
head = module.git(Path(sys.argv[2]), "rev-parse", "HEAD")
module.landing_evidence(Path(sys.argv[2]), head)
PY
  then
    fail "stale origin tracking ref still proved landing after remote deletion"
  fi
  pass "landing authority refreshes and prunes origin before proving reachability"
}

endpoint_authority_checkout_helper() {
  local tmp
  fm_test_tmproot_into tmp fm-worker-endpoint-authority
  # A production FM_HOME is a data home with no bin/. The backend helper must
  # resolve from the checkout that ships this tool; resolving it under the
  # home made every receipt die at rc 127 before any endpoint was probed.
  mkdir -p "$tmp/home/state" "$tmp/shim"
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-endpoint-authority-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  PATH="$tmp/shim:$PATH" python3 - "$AUTHORITY" "$tmp/home" <<'PY' || fail "endpoint authority did not resolve its helper from the checkout"
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
assert not (home / "bin").exists()
evidence = module.endpoint_evidence(home, "task-x", {"backend": ["tmux"], "window": ["fmtest:1"]})
assert b"absent" in evidence
PY
  pass "endpoint authority sources the checkout backend helper against a binless home"
}

account_authority_real_helper() {
  local tmp
  fm_test_tmproot_into tmp fm-worker-account-authority
  mkdir -p "$tmp/accounts/claude/3"
  ln -s "$tmp/accounts/claude/3" "$tmp/accounts/claude/link"
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
  FM_ACCOUNT_DIRECTORY_ROOT="$tmp/accounts" \
  python3 - "$AUTHORITY" "$tmp" "$tmp/accounts/claude/3" "$tmp/accounts/claude/link" <<'PY' || fail "account authority against the real helper failed"
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("worker_authority", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
home = Path(sys.argv[2])
assert not (home / "bin").exists()
values = {"account_home": [sys.argv[3]], "account_task": ["task-x"]}
evidence = module.account_evidence(values, "task-x", home)
assert b"ordinary-account-owner" in evidence
try:
    module.account_evidence({"account_home": [sys.argv[3]], "account_task": ["other"]}, "task-x", home)
except module.AuthorityError as exc:
    assert "task identity differs" in str(exc)
else:
    raise AssertionError("foreign account task was accepted")
try:
    module.account_evidence({"account_home": [sys.argv[4]], "account_task": ["task-x"]}, "task-x", home)
except module.AuthorityError:
    pass
else:
    raise AssertionError("symlinked account home was accepted")
PY
  pass "account authority proves the exact home through the real sourceable helper"
}

partial_apply_never_persists() {
  # The worker record is built from the controller's own expected_tags, and it
  # is proved real by a VALID apply succeeding against it before anything is
  # corrupted: a fixture the production function rejects would fail there
  # rather than silently make the later assertion vacuous.
  python3 - "$CONTROLLER" <<'PY' \
    || fail "a failed apply left its partial effects on the durable record"
import copy
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

WORKER = {
    "slot": 1,
    "queue_key": "one@spawn:aaaaaaaaaaaaaaaa",
    "assignment_generation": "asg-00000001",
    "deployment_generation": "dep-one",
    "owner": "owner",
    "phase": "creating",
    "resources": {},
    "bindings": {
        "home_binding": "h" * 64,
        "task": "one",
        "task_generation": "spawn:aaaaaaaaaaaaaaaa",
        "assignment_generation": "asg-00000001",
        "account_binding": "a" * 64,
        "worktree_binding": "w" * 64,
        "repository_binding": "r" * 64,
        "repository_generation": "c" * 40,
    },
}
TAGS = controller.expected_tags(WORKER)
CLOUD = {
    "slot": 1,
    "resources": {
        kind: {
            "id": "/subscriptions/s/resourceGroups/g/providers/x/{}".format(kind),
            "immutable_id": "imm-{}".format(kind),
            "tags": dict(TAGS),
        }
        for kind in controller.REQUIRED_RESOURCE_KINDS
    },
}


def document():
    return {
        "workers": {"1": copy.deepcopy(WORKER)},
        "queue": {WORKER["queue_key"]: {"status": "queued", "slot": None}},
        "executions": {},
        "completed_worker_seconds": 0.0,
        "capacity_reservations": {},
        "next_assignment": 2,
        "pending_action": None,
    }


action = {"type": "create", "slot": 1, "idempotency_key": "k", "request_digest": "d"}

# The fixture is real enough for the production function: a valid apply lands.
proof = document()
controller.apply_result_transactionally(
    {}, proof, action, {"idempotency_key": "k", "worker": copy.deepcopy(CLOUD)}
)
assert proof["workers"]["1"]["phase"] == "assigned", proof["workers"]["1"]["phase"]
assert proof["queue"][WORKER["queue_key"]]["status"] == "assigned"

# The guard at its call site, not only as a function. Deleting the
# assert_scoped call from apply_result_transactionally leaves every other
# assertion in this file green, which is exactly the hole this closes: the
# guard is the whole reason the change exists.
original_apply = controller.apply_action_result


def reaches_outside(env, document_, action_, result_):
    original_apply(env, document_, action_, result_)
    document_["capacity_reservations"]["rogue"] = 1


controller.apply_action_result = reaches_outside
scoped = document()
raised = None
try:
    controller.apply_result_transactionally(
        {}, scoped, action, {"idempotency_key": "k", "worker": copy.deepcopy(CLOUD)}
    )
except controller.LifecycleError as error:
    raised = error
finally:
    controller.apply_action_result = original_apply
assert raised is not None, "apply_result_transactionally committed an out-of-scope apply"
# Refused for the right reason, not merely refused.
assert "capacity_reservations" in str(raised), str(raised)
assert scoped == document(), "an out-of-scope apply reached the caller's record"

# Now the same apply with every resource identity moved. adopt_cloud_resources
# writes the whole resource set onto the record and only then refuses it, so
# that write is the partial effect under test.
moved = copy.deepcopy(CLOUD)
for kind in moved["resources"]:
    moved["resources"][kind]["tags"]["worker-slot"] = "99"
result = {"idempotency_key": "k", "worker": moved}

transactional = document()
raised = None
try:
    controller.apply_result_transactionally({}, transactional, action, result)
except controller.LifecycleError as error:
    raised = error
assert raised is not None, "a moved identity was accepted"
assert transactional == document(), "a failed apply changed the durable record"

# The in-place apply this replaces does leave those effects behind, which is
# what makes the assertion above a difference rather than a restatement.
loose = document()
try:
    controller.apply_action_result({}, loose, action, result)
except controller.LifecycleError:
    pass
assert loose != document(), "the in-place apply did not partially apply, so this proves nothing"
assert loose["workers"]["1"]["resources"], "the partial effect was not the adopted resource set"
PY

  # The production call site, not just the function it should call. Asserting
  # the property of apply_result_transactionally alone left execute_action free
  # to go back to the in-place apply with the suite still green.
  local tmp home envfile
  fm_test_tmproot_into tmp fm-worker-callsite
  home="$tmp/home"
  mkdir -p "$home"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=/bin/false
EOF
  python3 - "$CONTROLLER" "$envfile" <<'PY' \
    || fail "execute_action persisted a partially applied worker record"
import copy
import importlib.util
import json
import os
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

for line in open(sys.argv[2]):
    if "=" in line:
        name, value = line.strip().split("=", 1)
        os.environ[name] = value
env = controller.environment()

WORKER = {
    "slot": 1, "queue_key": "one@spawn:aaaaaaaaaaaaaaaa",
    "assignment_generation": "asg-00000001", "deployment_generation": "dep-one",
    "owner": "owner", "phase": "creating", "resources": {},
    "bindings": {
        "home_binding": "h" * 64, "task": "one",
        "task_generation": "spawn:aaaaaaaaaaaaaaaa",
        "assignment_generation": "asg-00000001", "account_binding": "a" * 64,
        "worktree_binding": "w" * 64, "repository_binding": "r" * 64,
        "repository_generation": "c" * 40,
    },
}
TAGS = controller.expected_tags(WORKER)
moved = {
    kind: {
        "id": "/subscriptions/s/resourceGroups/g/providers/x/{}".format(kind),
        "immutable_id": "imm-{}".format(kind),
        "tags": {**TAGS, "worker-slot": "99"},
    }
    for kind in controller.REQUIRED_RESOURCE_KINDS
}
# A real minted action: the call-site sequence durably claims it, and the claim
# must self-hash at save, so a fake key would make this unit die at the save
# and never reach the moved-identity apply it exists to test.
MINT_WORKER = dict(copy.deepcopy(WORKER), sku="sku", sku_family="fam",
                   cloud_generation=1, cloud_instance_id=None, reservation_usd=1.0)
action = controller.make_action(
    {"deployment_generation": "dep-one", "owner": "owner"}, "create",
    worker=MINT_WORKER, item={"task": "one", "task_generation": "spawn:aaaaaaaaaaaaaaaa"})

# The provider is the only thing stubbed, at the RAW boundary below the
# mutate ban; claim_pending, provider_mutate, apply_pending and drain_pending
# are the real ones, driven in the exact call-site sequence.
import contextlib as _ctx

def _stub(resources):
    def raw(environment, operation, payload):
        return {"result": {"idempotency_key": payload["idempotency_key"],
                           "worker": {"slot": 1, "resources": copy.deepcopy(resources)}}}
    return raw

good = {
    kind: {
        "id": "/subscriptions/s/resourceGroups/g/providers/x/{}".format(kind),
        "immutable_id": "imm-{}".format(kind),
        "tags": dict(TAGS),
    }
    for kind in controller.REQUIRED_RESOURCE_KINDS
}

# The mutate ban: no call site can reach the provider without a lease.
banned = None
try:
    controller.provider_call(env, "mutate", action)
except controller.LifecycleError as error:
    banned = error
assert banned is not None and "slot lease" in str(banned), banned

controller._provider_call_raw = _stub(moved)
with _ctx.ExitStack() as stack:
    with controller.controller_lock(env):
        state = controller.load_state(env)
        state["workers"]["1"] = copy.deepcopy(WORKER)
        state["queue"][WORKER["queue_key"]] = {"status": "queued", "slot": None}
        lease = stack.enter_context(controller.slot_lease(env, 1))
        controller.claim_pending(env, state, action)

    # The claim is durable BEFORE any provider call: a crash in the provider
    # window leaves a replay obligation, proven from the file.
    durable = json.loads(env["state_path"].read_text())
    assert durable["pending_actions"]["1"]["idempotency_key"] == action["idempotency_key"], (
        "claim_pending returned without a durable claim on its slot")

    # A DIFFERENT key on a claimed slot refuses: the blind overwrite that used
    # to discard the first claim and run the guest twice is closed.
    other = controller.make_action(
        {"deployment_generation": "dep-one", "owner": "owner"}, "deallocate",
        worker=MINT_WORKER)
    with controller.controller_lock(env):
        second = controller.load_state(env)
        blocked = None
        try:
            controller.claim_pending(env, second, other)
        except controller.LifecycleError as error:
            blocked = error
    assert blocked is not None and "still has an unapplied" in str(blocked), blocked

    # A lease on the wrong slot never reaches the provider.
    wrong = None
    try:
        controller.provider_mutate(env, dict(other, slot=2), lease)
    except controller.LifecycleError as error:
        wrong = error
    assert wrong is not None and "slot's lease" in str(wrong), wrong

    result = controller.provider_mutate(env, action, lease)
    with controller.controller_lock(env):
        raised = None
        try:
            controller.apply_pending(env, action, result)
        except controller.LifecycleError as error:
            raised = error
assert raised is not None, "apply_pending accepted a moved identity"
assert "identity" in str(raised) or "foreign" in str(raised) or "exact" in str(raised), (
    "the refusal was not the apply's; the unit degraded into testing something else", str(raised))

# The failed apply changed NOTHING durable: the point-3 image (claim present,
# worker untouched) is still exactly what the file holds.
durable = json.loads(env["state_path"].read_text())
assert durable["pending_actions"]["1"]["idempotency_key"] == action["idempotency_key"], (
    "a failed apply erased the durable replay obligation")
assert durable["workers"]["1"]["phase"] == "creating"
assert not durable["workers"]["1"]["resources"], (
    "a failed apply left adopted resources on the durable record")

# drain_pending with strict=False records the refusal and RETAINS the claim;
# the wedge stays visible instead of being silently discarded.
drained, refusals = controller.drain_pending(env, strict=False)
assert drained == [] and len(refusals) == 1 and refusals[0]["slot"] == 1, (drained, refusals)
durable = json.loads(env["state_path"].read_text())
assert durable["pending_actions"]["1"]["idempotency_key"] == action["idempotency_key"], (
    "a refused replay dropped the claim")
assert any("provider mutation result" in str(entry.get("note", "")) or entry
           for entry in durable["cleanup_refusals"])

# With an honest provider result, the drain applies and clears the claim.
controller._provider_call_raw = _stub(good)
drained, refusals = controller.drain_pending(env, strict=False)
assert drained == ["1"] and refusals == [], (drained, refusals)
durable = json.loads(env["state_path"].read_text())
assert durable["pending_actions"] == {}, "a successful apply left its claim behind"
assert durable["workers"]["1"]["resources"], "the applied create adopted nothing"

# Applying an action whose durable claim is GONE refuses on the fresh load:
# without this, a caller that lost a race with the drain (or with an operator
# abandon) would apply the same mutation's effects a second time.
with controller.controller_lock(env):
    stale_apply = None
    try:
        controller.apply_pending(env, action, {"idempotency_key": action["idempotency_key"],
                                               "worker": {"slot": 1, "resources": good}})
    except controller.LifecycleError as error:
        stale_apply = error
assert stale_apply is not None and "no longer this action" in str(stale_apply), stale_apply

# abandon-claim's under-lease re-read: a claim a concurrent drain applied
# between abandon's pre-check and its lease must refuse WITHOUT re-sending
# the mutation. The load sequence is substituted (present at the pre-check,
# gone under the lease); the raw provider boundary asserts no call happens.
import types as _types
real_load = controller.load_state
with controller.controller_lock(env):
    seeded = real_load(env)
    seeded["workers"]["1"] = copy.deepcopy(WORKER)
    seeded["pending_actions"]["1"] = copy.deepcopy(action)
    controller.save_state(env, seeded)
loads = {"count": 0}
def sequenced_load(environment):
    loads["count"] += 1
    state = real_load(environment)
    if loads["count"] >= 2:
        state["pending_actions"].pop("1", None)
    return state
def never_mutate(environment, operation, payload):
    raise AssertionError("abandon re-sent a mutation after its claim was applied elsewhere")
controller.load_state = sequenced_load
controller._provider_call_raw = never_mutate
raced = None
try:
    controller.command_abandon_claim(env, _types.SimpleNamespace(
        slot="1", idempotency_key=action["idempotency_key"],
        confirm_abandon=True, confirm_subscription=env["subscription"]))
except controller.LifecycleError as error:
    raced = error
finally:
    controller.load_state = real_load
assert raced is not None and "changed while abandoning" in str(raced), raced
with controller.controller_lock(env):
    cleanup = real_load(env)
    cleanup["pending_actions"].pop("1", None)
    controller.save_state(env, cleanup)
PY

  # An apply whose effects reach outside the slot it names is refused rather
  # than committed, which is the property that will let two slots mutate at
  # once.
  python3 - "$CONTROLLER" <<'PY' || fail "an out-of-scope apply was committed"
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)

before = {"workers": {"1": {"slot": 1}, "2": {"slot": 2}}, "queue": {}, "executions": {},
          "completed_worker_seconds": 0.0, "capacity_reservations": {}, "next_assignment": 3}
for changed, why in (
    ({"workers": {"1": {"slot": 1}, "2": {"slot": 2, "phase": "x"}}}, "another slot's worker"),
    ({"queue": {"other": {}}}, "a queue entry the slot does not own"),
    ({"capacity_reservations": {"r": 1}}, "capacity reservations"),
    ({"next_assignment": 9}, "the fleet assignment counter"),
    ({"executions": {"elsewhere": {}}}, "an execution it did not request"),
):
    after = dict(before)
    after.update(changed)
    try:
        controller.assert_scoped(before, after, slot="1", queue_key=None, request_digest=None)
    except controller.LifecycleError:
        continue
    raise AssertionError("an apply that changed {} was accepted".format(why))

# The compartment it DOES own is allowed, or this would refuse every real apply.
allowed = dict(before)
allowed.update({
    "workers": {"1": {"slot": 1, "phase": "assigned"}, "2": {"slot": 2}},
    "queue": {"mine": {"status": "assigned"}},
    "executions": {"d": {}},
    "completed_worker_seconds": 12.0,
})
controller.assert_scoped(before, allowed, slot="1", queue_key="mine", request_digest="d")

# And a reset removes the worker outright, which the allowlist must permit.
removed = dict(before)
removed.update({"workers": {"2": {"slot": 2}}})
controller.assert_scoped(before, removed, slot="1", queue_key=None, request_digest=None)
PY

  pass "a provider mutation that fails partway leaves the durable record untouched, and one that reaches outside its slot is refused"
}

restart_idempotency() {
  local tmp provider fixture home
  fm_test_tmproot_into tmp fm-worker-restart
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    python3 - "$CONTROLLER" <<'PY' || fail "restart idempotency fixture failed"
import json
import os
from pathlib import Path
import sys

import importlib.util
spec = importlib.util.spec_from_file_location("lifecycle_restart", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = module.environment()
item = {
    "schema": module.REQUEST_SCHEMA, "task": "restart-task", "task_generation": "restart-gen",
    "repository_generation": "repo-gen", "home_binding": "1" * 64,
    "account_binding": "2" * 64, "worktree_binding": "3" * 64,
    "repository_binding": "4" * 64, "owner_kind": "primary", "role": "author",
    "eligible": True, "discretionary": True, "status": "queued", "enqueued_at": module.iso_utc(),
}
item2 = dict(item, task="restart-task-two", task_generation="restart-gen-two",
             home_binding="5" * 64, account_binding="6" * 64,
             worktree_binding="7" * 64, repository_binding="8" * 64)
actions = []
with module.controller_lock(env):
    state = module.load_state(env)
    for entry in (item, item2):
        state["queue"][module.request_key(entry["task"], entry["task_generation"])] = entry
    inventory = module.provider_call(env, "inventory")["inventory"]
    revision_before = state["revision"]
    for _ in range(2):
        # Each planning pass claims the next free slot; parking the claim on
        # the map (without applying) is exactly the crash-before-apply image,
        # and two of them at once is the shape the scalar could never hold.
        action = module.next_reconcile_action(env, state, inventory)
        state["pending_actions"][str(action["slot"])] = action
        module.save_state(env, state)
        actions.append(action)
assert sorted(str(a["slot"]) for a in actions) == ["1", "2"]
for action in actions:
    # The provider completed, but the controller process is modeled as dying
    # before it durably applied the response. Submission goes through the only
    # legal mutate path: a live lease on the exact slot.
    with module.slot_lease(env, action["slot"]) as lease:
        module.provider_mutate(env, action, lease)

with module.controller_lock(env):
    restarted = module.load_state(env)
    assert restarted["pending_action"] == module.LEGACY_PENDING_SENTINEL
    assert restarted["revision"] > revision_before
    for action in actions:
        held = restarted["pending_actions"][str(action["slot"])]
        assert held["idempotency_key"] == action["idempotency_key"]
drained, refusals = module.drain_pending(env)
assert sorted(drained) == ["1", "2"] and refusals == [], (drained, refusals)
with module.controller_lock(env):
    drained_state = module.load_state(env)
    assert drained_state["pending_actions"] == {}
    assert len(drained_state["workers"]) == 2
fixture = json.loads(Path(os.environ["FIXTURE_STATE"]).read_text())
for action in actions:
    matching = [call for call in fixture["calls"] if call["key"] == action["idempotency_key"]]
    assert len(matching) == 2, (action["slot"], len(matching))
assert len(fixture["seen"]) == 2 and len(fixture["workers"]) == 2
PY
  pass "restart replays each per-slot idempotency key exactly once without duplicating assignment"
}


surrender_lane() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-surrender
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF

  python3 - "$CONTROLLER" "$WRAPPER" "$envfile" "$fixture" <<'PY' || fail "surrender lane exercise failed"
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

controller_path, wrapper, envfile, fixture_path = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

def controller_state():
    return json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())

run(
    "request", "--task", "task-1", "--task-generation", "gen-1",
    "--home-binding", binding(1001), "--account-binding", binding(2001),
    "--worktree-binding", binding(3001), "--repository-binding", binding(4001),
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible",
)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
assert state["queue"]["task-1@gen-1"]["status"] == "assigned"
slot = str(state["queue"]["task-1@gen-1"]["slot"])

surrender = [
    "surrender", "--task", "task-1", "--task-generation", "gen-1",
    "--reason", "local teardown consumed the task metadata before any receipt existed",
    "--output", str(Path(env["FM_HOME"]) / "surrender-1.json"),
]
confirm = ["--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]]

# Confirmation gates.
refused = run(*surrender, *confirm, check=False)
assert refused.returncode != 0 and "--confirm-surrender" in refused.stderr, refused.stderr
refused = run(*surrender, "--confirm-surrender", "--confirm-subscription", "22222222-2222-4222-8222-222222222222", check=False)
assert refused.returncode != 0 and "confirm-subscription" in refused.stderr, refused.stderr
refused = run(*surrender[:-2], "--output", surrender[-1], "--reason", " ", "--confirm-surrender", *confirm, check=False)
assert refused.returncode != 0 and "--reason" in refused.stderr, refused.stderr

# Live compute refuses: the fixture VM is running.
refused = run(*surrender, "--confirm-surrender", *confirm, check=False)
assert refused.returncode != 0 and "dark compute" in refused.stderr, refused.stderr
assert controller_state()["workers"][slot].get("release_proof") is None

# The TTL fires outside the controller: model it in provider-side cloud state.
fixture = json.loads(Path(fixture_path).read_text())
fixture["workers"][slot]["resources"]["vm"]["power_state"] = "VM deallocated"
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")) + "\n")

# Durable execution evidence of unlanded work blocks the lane until the
# discard is named, and the named discard is recorded in the proof. The
# record is injected into durable controller state exactly where
# apply_action_result persists executions.
state = controller_state()
evidence_digest = "b" * 64
state["executions"][evidence_digest] = {
    "task": "task-1", "task_generation": "gen-1",
    "assignment_generation": state["workers"][slot]["assignment_generation"],
    "outcome_present": True, "outcome_commits": 1,
}
(Path(env["FM_HOME"]) / "state/azure-workers/controller.json").write_text(
    json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
refused = run(*surrender, "--confirm-surrender", *confirm, check=False)
assert refused.returncode != 0 and evidence_digest in refused.stderr, refused.stderr
assert controller_state()["workers"][slot].get("release_proof") is None

# The ordinary authority genuinely refuses here (no task metadata exists in
# this home), so surrender proceeds against dark compute once the discard is
# deliberately named.
staged = Path(env["FM_HOME"]) / "state" / "task-1.cloud-account"
staged.mkdir(parents=True)
(staged / "auth.json").write_text("{}")
result = run(*surrender, "--confirm-surrender", "--confirm-discard-unlanded", *confirm)
assert "FM-SURRENDERED task-1 gen-1" in result.stdout, result.stdout
assert not staged.exists(), "staged provider credential survived the surrender receipt"

state = controller_state()
worker = state["workers"][slot]
proof = worker["release_proof"]
assert state["queue"]["task-1@gen-1"]["status"] == "releasing"
assert worker["phase"] == "release-proved"
assert proof["surrender"]["reason"].startswith("local teardown")
assert proof["surrender"]["ordinary_refusal"]
assert proof["surrender"]["discarded_unlanded_executions"] == [evidence_digest]
assert all(v["verdict"] == "surrendered" for v in proof["authorities"].values())
written = json.loads((Path(env["FM_HOME"]) / "surrender-1.json").read_text())
assert written == proof

# The proof digest round-trips the canonical digest, and the ordinary release
# command refuses the surrender bundle outright.
unsigned = dict(proof)
supplied = unsigned.pop("proof_digest")
recomputed = hashlib.sha256(json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
assert supplied == recomputed, "surrender proof digest does not round-trip"
import importlib.util
spec = importlib.util.spec_from_file_location("controller", controller_path)
controller = importlib.util.module_from_spec(spec)
spec.loader.exec_module(controller)
try:
    controller.release_receipt(state, str(Path(env["FM_HOME"]) / "surrender-1.json"))
except controller.LifecycleError as exc:
    assert "did not prove release safety" in str(exc), exc
else:
    raise AssertionError("the ordinary release validator accepted a surrendered verdict")

# Re-running is idempotent and re-issues the receipt without a second proof.
(Path(env["FM_HOME"]) / "surrender-1.json").unlink()
again = run(*surrender, "--confirm-surrender", *confirm)
assert "already recorded" in again.stdout and "FM-SURRENDERED task-1 gen-1" in again.stdout
assert controller_state()["workers"][slot]["release_proof"] == proof
rewritten = json.loads((Path(env["FM_HOME"]) / "surrender-1.json").read_text())
assert rewritten == proof, "the idempotent rerun did not re-issue the exact stored proof"

# Reconcile now converges the surrendered slot to nothing through the ordinary
# fenced machinery: delete-compute, then reset.
for _ in range(4):
    run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
assert state["workers"] == {}, state["workers"]
assert state["queue"]["task-1@gen-1"]["status"] == "complete"
assert slot not in json.loads(Path(fixture_path).read_text())["workers"]
PY
  pass "surrender releases an authority-less worker through refusal-first gates and ordinary reset"
}

surrender_refuses_when_ordinary_authority_passes() {
  # The gate under test is the caller's reaction to an authority SUCCESS. The
  # subprocess contract itself (argv shape, refusal capture) is exercised for
  # real in surrender_lane above; here only the attempt outcome is substituted,
  # at module level, to prove success closes the lane.
  local tmp
  fm_test_tmproot_into tmp fm-worker-surrender-authority-pass
  mkdir -p "$tmp/home"
  python3 - "$CONTROLLER" "$tmp/home" <<'PY' || fail "surrender accepted a worker the ordinary release lane can still prove"
import importlib.util
import json
import sys
import types
from pathlib import Path

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

home = Path(sys.argv[2])
(home / "state/azure-workers").mkdir(parents=True)
env = {
    "home": home, "state_dir": home / "state/azure-workers",
    "subscription": "11111111-1111-4111-8111-111111111111",
}
worker = {
    "slot": 1, "queue_key": "task-1@gen-1", "assignment_generation": "asg-00000001",
    "cloud_instance_id": "cloud-1", "resources": {},
    "bindings": {
        "home_binding": "1" * 64, "task": "task-1", "task_generation": "gen-1",
        "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
        "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
        "repository_generation": "repo-1",
    },
}
state = {
    "queue": {"task-1@gen-1": {"status": "assigned", "slot": 1, "task": "task-1", "task_generation": "gen-1"}},
    "workers": {"1": worker},
    "pending_action": None,
}

module.load_state = lambda _env: state
module.controller_lock = __import__("contextlib").nullcontext
module.save_state = lambda _env, _state: (_ for _ in ()).throw(AssertionError("a refused surrender persisted state"))
module.ordinary_authority_attempt = lambda _env, _args, _worker: None
module.provider_call = lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("surrender consulted the provider after an authority success"))

args = types.SimpleNamespace(
    task="task-1", task_generation="gen-1", reason="reason", output=str(home / "out.json"),
    confirm_surrender=True, confirm_subscription="11111111-1111-4111-8111-111111111111",
)
try:
    module.command_surrender(env, args)
except module.LifecycleError as exc:
    assert "ordinary release authority succeeded" in str(exc), exc
else:
    raise AssertionError("surrender did not refuse a provable ordinary release")
assert worker.get("release_proof") is None
PY
  pass "surrender refuses when the ordinary release authority still succeeds"
}



surrender_refusal_matrix() {
  # Every advertised surrender refusal, pinned at the command against durable
  # state the production loader accepts. The provider is only consulted where
  # the gate under test sits past the inventory read.
  local tmp
  fm_test_tmproot_into tmp fm-worker-surrender-refusals
  mkdir -p "$tmp/home"
  python3 - "$CONTROLLER" "$tmp/home" <<'PY' || fail "a surrender refusal gate is not enforced"
import contextlib
import importlib.util
import json
import sys
import types
from pathlib import Path

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

home = Path(sys.argv[2])
(home / "state/azure-workers").mkdir(parents=True)
env = {
    "home": home, "state_dir": home / "state/azure-workers",
    "subscription": "11111111-1111-4111-8111-111111111111",
}
# Captured before any expect_refusal stomps the module attribute: the
# fail-closed block below must drive the REAL classification code.
real_attempt = module.ordinary_authority_attempt

def worker_record():
    return {
        "slot": 1, "queue_key": "task-1@gen-1", "assignment_generation": "asg-00000001",
        "cloud_instance_id": "cloud-1", "resources": {}, "phase": "assigned",
        "bindings": {
            "home_binding": "1" * 64, "task": "task-1", "task_generation": "gen-1",
            "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
            "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
            "repository_generation": "repo-1",
        },
    }

def base_state():
    return {
        "queue": {"task-1@gen-1": {"status": "assigned", "slot": 1, "task": "task-1", "task_generation": "gen-1"}},
        "workers": {"1": worker_record()},
        "pending_action": None,
        "pending_actions": {},
        "executions": {},
    }

def args(**overrides):
    value = types.SimpleNamespace(
        task="task-1", task_generation="gen-1", reason="reason",
        output=str(home / "out.json"), confirm_surrender=True,
        confirm_discard_unlanded=False,
        confirm_subscription="11111111-1111-4111-8111-111111111111",
    )
    for key, item in overrides.items():
        setattr(value, key, item)
    return value

def expect_refusal(state, call_args, fragment, *, attempt=None, provider=None):
    module.load_state = lambda _env: state
    module.controller_lock = contextlib.nullcontext
    module.save_state = lambda _env, _state: (_ for _ in ()).throw(
        AssertionError("a refused surrender persisted state"))
    module.ordinary_authority_attempt = attempt or (
        lambda *_a: (_ for _ in ()).throw(AssertionError("authority consulted past the gate under test")))
    module.provider_call = provider or (
        lambda *_a, **_k: (_ for _ in ()).throw(AssertionError("provider consulted past the gate under test")))
    try:
        module.command_surrender(env, call_args)
    except module.LifecycleError as exc:
        assert fragment in str(exc), (fragment, str(exc))
    else:
        raise AssertionError("surrender did not refuse: {}".format(fragment))

# Malformed identities refuse before anything else runs.
expect_refusal(base_state(), args(task="../escape"), "bounded identifier characters")

# A pending provider action blocks the whole lane.
state = base_state()
state["pending_actions"] = {"2": {"type": "execute", "request": {"task": "other", "task_generation": "gen-9"}}}
expect_refusal(state, args(), "pending provider action")

# A converged entry names its credential recovery instead of a generic refusal.
state = base_state()
state["queue"]["task-1@gen-1"]["status"] = "complete"
del state["workers"]["1"]
expect_refusal(state, args(), "fm_cloud_state_remove")

# An ordinary release proof is never replaced or re-issued by surrender.
state = base_state()
state["workers"]["1"]["release_proof"] = {"schema": "fm.worker-release/v2", "proof_digest": "a" * 64}
expect_refusal(state, args(), "ordinary release proof")

# A stored surrender proof for a DIFFERENT generation is never re-issued.
state = base_state()
state["queue"]["task-1@gen-1"]["status"] = "releasing"
state["workers"]["1"]["release_proof"] = {
    "schema": "fm.worker-release/v2", "task": "task-1", "task_generation": "gen-OTHER",
    "surrender": {"reason": "x"}, "proof_digest": "a" * 64,
}
expect_refusal(state, args(), "different task generation")

# Durable execution evidence of unlanded repository work outranks the operator
# unless the discard is named; the refusal must list the exact execution.
for evidence in (
    {"outcome_present": True},
    {"outcome_uncommitted_changes": True},
    {"outcome_commits": 2},
):
    state = base_state()
    record = {"task": "task-1", "task_generation": "gen-1", "assignment_generation": "asg-00000001"}
    record.update(evidence)
    state["executions"]["e" * 64] = record
    expect_refusal(state, args(), "e" * 64)

# The authority tool breaking is NOT a refusal: surrender stays closed. The
# subprocess boundary is substituted; the classification of its outcome is the
# real production code.
real_run = module.subprocess.run
try:
    module.subprocess.run = lambda *_a, **_k: types.SimpleNamespace(
        returncode=1, stderr=b"Traceback (most recent call last): KeyError: 'window'", stdout=b"")
    try:
        real_attempt(env, args(), worker_record())
    except module.LifecycleError as exc:
        assert "failed rather than refusing" in str(exc), exc
    else:
        raise AssertionError("a broken authority tool unlocked surrender")
    module.subprocess.run = lambda *_a, **_k: types.SimpleNamespace(
        returncode=2, stderr=b"WORKER AUTHORITY REFUSED: ordinary task metadata authority is absent", stdout=b"")
    refusal = real_attempt(env, args(), worker_record())
    assert "metadata authority is absent" in refusal
finally:
    module.subprocess.run = real_run

# A worker the live inventory cannot prove assigned is ambiguous, not
# surrenderable - including a slot absent from inventory entirely.
state = base_state()
expect_refusal(
    state, args(), "non-assigned or ambiguous",
    attempt=lambda *_a: "WORKER AUTHORITY REFUSED: fixture refusal",
    provider=lambda *_a, **_k: {"inventory": {"workers": []}},
)
PY
  pass "every advertised surrender refusal is enforced at the command"
}



legacy_scalar_migration() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-legacy-migration
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF

  python3 - "$CONTROLLER" "$WRAPPER" "$envfile" <<'PY' || fail "the legacy scalar pending action did not migrate onto the map"
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

controller_path, wrapper, envfile = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

spec = importlib.util.spec_from_file_location("controller", controller_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for key, value in ((k, v) for k, v in env.items() if k.startswith("FM")):
    os.environ[key] = value
menv = module.environment()

# A pre-map controller.json: populated scalar, no pending_actions, no revision.
# The action must be REAL: after migration verify_state re-derives its key.
worker = {
    "slot": 1, "sku": "sku", "sku_family": "fam", "cloud_generation": 1,
    "cloud_instance_id": None, "reservation_usd": 1.0, "resources": {},
    "bindings": {"task": "legacy-task", "task_generation": "legacy-gen"},
}
action = module.make_action(
    {"deployment_generation": menv["deployment_generation"], "owner": menv["owner"]},
    "create", worker=worker, item={"task": "legacy-task", "task_generation": "legacy-gen"})
legacy = module.empty_state(menv)
legacy["pending_action"] = action
del legacy["pending_actions"]
del legacy["revision"]
path = Path(env["FM_HOME"]) / "state/azure-workers"
path.mkdir(parents=True)
(path / "controller.json").write_text(json.dumps(legacy, sort_keys=True, separators=(",", ":")))

# A read-only command loads the legacy file.
result = subprocess.run([wrapper, "status", "--json"], env=env, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == 0, result.stderr
status = json.loads(result.stdout)
assert status["pending_mutations"] == [{"slot": 1, "type": "create", "lease_held": False}], status["pending_mutations"]

# A saving command makes the migration durable.
result = subprocess.run([
    wrapper, "request", "--task", "fresh-task", "--task-generation", "fresh-gen",
    "--home-binding", "1" * 64, "--account-binding", "2" * 64,
    "--worktree-binding", "3" * 64, "--repository-binding", "4" * 64,
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible",
], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == 0, result.stderr
durable = json.loads((path / "controller.json").read_text())
assert durable["pending_actions"]["1"]["idempotency_key"] == action["idempotency_key"]
assert durable["pending_action"] == "superseded-by-pending-actions"
assert durable["revision"] >= 1
PY
  pass "a legacy scalar pending action migrates onto the map and poisons the scalar"
}

state_fence_and_revision_cas() {
  local tmp home
  fm_test_tmproot_into tmp fm-worker-state-fence
  home="$tmp/home"
  mkdir -p "$home"
  FM_HOME="$home" \
  FM_AZURE_SUBSCRIPTION_ID=$SUB \
  FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
  FM_AZURE_OWNER_TAG=owner \
  FM_AZURE_NAMING_PREFIX=fmtest \
  python3 - "$CONTROLLER" <<'PY' || fail "the load fence, revision CAS, or re-entrancy refusal is not enforced"
import importlib.util
import json
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
env = module.environment()

# Re-entrant acquisition refuses instead of deadlocking.
with module.controller_lock(env):
    try:
        with module.controller_lock(env):
            pass
    except module.LifecycleError as exc:
        assert "already held" in str(exc), exc
    else:
        raise AssertionError("re-entrant controller lock acquisition was allowed")

# A state loaded outside the committing lock hold refuses to save.
with module.controller_lock(env):
    stale = module.load_state(env)
    module.save_state(env, stale)
with module.controller_lock(env):
    try:
        module.save_state(env, stale)
    except module.LifecycleError as exc:
        assert "outside the committing lock hold" in str(exc), exc
    else:
        raise AssertionError("a state loaded under an earlier hold was committed")

# A plain dict never saves, whatever it claims to be.
with module.controller_lock(env):
    fresh = module.load_state(env)
    try:
        module.save_state(env, dict(fresh))
    except module.LifecycleError as exc:
        assert "not loaded through load_state" in str(exc), exc
    else:
        raise AssertionError("an unfenced document was committed")

# A tampered claim refuses at load: the stored bytes no longer re-derive
# the stored idempotency key, so a hand-edited, truncated, or fabricated
# claim cannot ride the map into a replay.
with module.controller_lock(env):
    doc = module.load_state(env)
    worker = {
        "slot": 1, "sku": "sku", "sku_family": "fam", "cloud_generation": 1,
        "cloud_instance_id": None, "reservation_usd": 1.0, "resources": {},
        "bindings": {"task": "t", "task_generation": "g"},
    }
    claim = module.make_action(
        {"deployment_generation": env["deployment_generation"], "owner": env["owner"]},
        "deallocate", worker=worker)
    doc["pending_actions"]["1"] = claim
    module.save_state(env, doc)
raw = json.loads(Path(env["state_path"]).read_text())
raw["pending_actions"]["1"]["cloud_generation"] = 7
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))
with module.controller_lock(env):
    try:
        module.load_state(env)
    except module.LifecycleError as exc:
        assert "pending provider action is malformed" in str(exc), exc
    else:
        raise AssertionError("a tampered claim loaded cleanly")
# Restore an honest document for the CAS case below.
raw["pending_actions"] = {}
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))

# A corrupt legacy scalar refuses at load instead of being paved over.
raw = json.loads(Path(env["state_path"]).read_text())
raw["pending_action"] = "corrupted-garbage"
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))
with module.controller_lock(env):
    try:
        module.load_state(env)
    except module.LifecycleError as exc:
        assert "pending provider action is malformed" in str(exc), exc
    else:
        raise AssertionError("a corrupt legacy scalar was silently paved over")

# A legacy scalar that DISAGREES with the map entry for its slot refuses.
raw["pending_action"] = claim
disagreeing = json.loads(json.dumps(claim))
disagreeing["cloud_generation"] = 2
disagreeing["idempotency_key"] = module.action_id(disagreeing)
raw["pending_actions"] = {"1": disagreeing}
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))
with module.controller_lock(env):
    try:
        module.load_state(env)
    except module.LifecycleError as exc:
        assert "disagree" in str(exc), exc
    else:
        raise AssertionError("disagreeing legacy and per-slot claims loaded cleanly")

# A claim naming a slot outside 1..MAX_WORKERS refuses, even when it
# self-hashes: the planner can never produce one, so it is a hand edit.
out_of_range = {
    "slot": 17, "sku": "sku", "sku_family": "fam", "cloud_generation": 1,
    "cloud_instance_id": None, "reservation_usd": 1.0, "resources": {},
    "bindings": {"task": "t", "task_generation": "g"},
}
range_claim = module.make_action(
    {"deployment_generation": env["deployment_generation"], "owner": env["owner"]},
    "deallocate", worker=out_of_range)
raw["pending_action"] = None
raw["pending_actions"] = {"17": range_claim}
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))
with module.controller_lock(env):
    try:
        module.load_state(env)
    except module.LifecycleError as exc:
        assert "pending provider action is malformed" in str(exc), exc
    else:
        raise AssertionError("a claim outside the slot range loaded cleanly")
raw["pending_actions"] = {}
Path(env["state_path"]).write_text(json.dumps(raw, sort_keys=True, separators=(",", ":")))

# The revision CAS: a concurrent writer moved the file after this load.
with module.controller_lock(env):
    mine = module.load_state(env)
    on_disk = json.loads(Path(env["state_path"]).read_text())
    on_disk["revision"] = int(on_disk.get("revision", 0)) + 1
    Path(env["state_path"]).write_text(json.dumps(on_disk, sort_keys=True, separators=(",", ":")))
    try:
        module.save_state(env, mine)
    except module.LifecycleError as exc:
        assert "revision moved from" in str(exc), exc
    else:
        raise AssertionError("a stale save overwrote a moved revision")
PY
  pass "the load fence, revision CAS, and re-entrancy refusal each fail loudly"
}



concurrent_mutations_do_not_serialize() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-concurrent
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home" "$tmp/barrier"
  mkfifo "$tmp/barrier/release"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
FIXTURE_BARRIER_DIR=$tmp/barrier
FIXTURE_BARRIER_TYPES=create
EOF

  FM_LIFECYCLE_CONTROLLER="$CONTROLLER" \
  python3 - "$WRAPPER" "$envfile" "$fixture" "$tmp/barrier" <<'PY' || fail "two provider mutations did not run concurrently"
import json
import os
from pathlib import Path
import subprocess
import sys
import time

wrapper, envfile, fixture_path, barrier = sys.argv[1:]
env = os.environ.copy()
env["FM_LIFECYCLE_CONTROLLER"] = os.environ.get("FM_LIFECYCLE_CONTROLLER", "")
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value
foreground = dict(env)
foreground.pop("FIXTURE_BARRIER_DIR", None)

def run(*args, check=True, environment=None):
    result = subprocess.run([wrapper] + list(args), env=environment or foreground,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

def request(number):
    run(
        "request", "--task", "task-{}".format(number), "--task-generation", "gen-{}".format(number),
        "--home-binding", binding(1000 + number), "--account-binding", binding(2000 + number),
        "--worktree-binding", binding(3000 + number), "--repository-binding", binding(4000 + number),
        "--repository-generation", "repo-{}".format(number), "--owner-kind", "primary", "--eligible",
    )

def controller_state():
    return json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())

def wait_for_arrivals(count, deadline_seconds):
    # A failure DETECTOR only, never an assertion of timing.
    arrived = Path(barrier) / "arrived"
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        if arrived.exists() and len(list(arrived.iterdir())) >= count:
            return True
        time.sleep(0.05)
    return False

request(1)
request(2)

# Two reconciles, each due to claim one create and park inside the provider.
children = [
    subprocess.Popen(
        [wrapper, "reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for _ in range(2)
]
try:
    # Load-bearing: under the old fleet-lock discipline the second caller
    # blocks at LOCK_EX before it ever reaches the provider, so a second
    # arrival is structurally unsatisfiable there.
    assert wait_for_arrivals(2, 60), "second mutation never reached the provider while the first was parked"

    state = controller_state()
    pending = state["pending_actions"]
    assert sorted(pending) == ["1", "2"], pending
    generations = {entry["bindings"]["assignment_generation"] for entry in pending.values()}
    assert len(generations) == 2, generations
    assert sorted(state["workers"]) == ["1", "2"], sorted(state["workers"])
    assert state["pending_action"] == "superseded-by-pending-actions"

    # Readers and unrelated mutations proceed while both are parked.
    status = json.loads(run("status", "--json").stdout)
    held = {entry["slot"]: entry["lease_held"] for entry in status["pending_mutations"]}
    assert held == {1: True, 2: True}, held
    dry = run("reconcile", "--json")
    assert json.loads(dry.stdout)["status"]["queue_depth"] >= 2
    request(9)
    run("withdraw", "--task", "task-9", "--task-generation", "gen-9", "--confirm-withdraw",
        "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])

    # The lease itself, against a LIVE cross-process holder: the parked child
    # owns slot 1's lease, so a second taker must refuse with SlotBusy at
    # once. This is the only behavioral pin the LOCK_NB discipline has; a
    # blocking lease here deadlocks the fleet-lock/lease cycle the design
    # rules out, so the probe runs in a bounded subprocess.
    probe = subprocess.run(
        [sys.executable, "-c", (
            "import importlib.util, sys\n"
            "spec = importlib.util.spec_from_file_location('c', sys.argv[1])\n"
            "m = importlib.util.module_from_spec(spec)\n"
            "spec.loader.exec_module(m)\n"
            "env = m.environment()\n"
            "try:\n"
            "    with m.slot_lease(env, 1):\n"
            "        print('ACQUIRED')\n"
            "except m.SlotBusy as exc:\n"
            "    print('BUSY:', exc)\n"
        ), os.environ.get("FM_LIFECYCLE_CONTROLLER", "")],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    assert probe.returncode == 0, probe.stderr
    assert "BUSY:" in probe.stdout and "owned by a live process" in probe.stdout, (
        "a live holder did not refuse a second lease taker immediately", probe.stdout, probe.stderr)

    # A steer at a PARKED slot refuses without a third provider call: the
    # queue entry is honestly still `assigning` while the create is in
    # flight, so the earliest gate fires. (The claimed-slot refusal itself,
    # "still has an unapplied ... action", is pinned at command level by the
    # end-to-end skew scenario.)
    arrivals_before = len(list((Path(barrier) / "arrived").iterdir()))
    blocked = run("steer", "--task", "task-1", "--task-generation", "gen-1",
                  "--assignment-generation", state["workers"]["1"]["assignment_generation"],
                  "--request-digest", "a" * 64, "--confirm-steer",
                  "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"], check=False)
    assert blocked.returncode != 0 and "one exact assigned task generation" in blocked.stderr, blocked.stderr
    assert len(list((Path(barrier) / "arrived").iterdir())) == arrivals_before
finally:
    with open(Path(barrier) / "release", "w") as gate:
        gate.write("xx")
    outcomes = [child.wait(timeout=120) for child in children]

assert outcomes == [0, 0], [child.stderr.read() for child in children]
state = controller_state()
fixture = json.loads(Path(fixture_path).read_text())
assert state["pending_actions"] == {}
assert len(fixture["workers"]) == 2 and len(fixture["seen"]) == 2
create_calls = [entry for entry in fixture["calls"] if entry["type"] == "create"]
per_key = {}
for entry in create_calls:
    per_key[entry["key"]] = per_key.get(entry["key"], 0) + 1
assert sorted(per_key.values()) == [1, 1], per_key
assert state["revision"] > 2

# Positive control: the same harness with ONE child must FAIL the two-arrival
# wait, or the wait proves nothing about concurrency.
for stale in (Path(barrier) / "arrived").iterdir():
    stale.unlink()
request(3)
lone = subprocess.Popen(
    [wrapper, "reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert not wait_for_arrivals(2, 5), "one child produced two arrivals; the detector is broken"
finally:
    with open(Path(barrier) / "release", "w") as gate:
        gate.write("x")
    assert lone.wait(timeout=120) == 0, lone.stderr.read()
PY
  pass "two slots' provider mutations run concurrently while readers and unrelated mutations proceed"
}

wedged_slot_does_not_stop_the_fleet() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-wedged
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF

  python3 - "$CONTROLLER" "$WRAPPER" "$envfile" "$fixture" <<'PY' || fail "a wedged slot stopped the fleet from converging"
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

controller_path, wrapper, envfile, fixture_path = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

spec = importlib.util.spec_from_file_location("controller", controller_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for key, value in ((k, v) for k, v in env.items() if k.startswith(("FM", "FIXTURE"))):
    os.environ[key] = value
menv = module.environment()

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

# A claim whose replay is guaranteed to refuse: a create naming a slot with no
# durable worker record. apply_action_result raises on the absent owner, so
# the drain records replay-refused and the claim stays.
worker9 = {
    "slot": 9, "sku": "sku", "sku_family": "fam", "cloud_generation": 1,
    "cloud_instance_id": None, "reservation_usd": 1.0, "resources": {},
    "bindings": {"task": "wedged", "task_generation": "gen-w"},
}
wedged = module.make_action(
    {"deployment_generation": menv["deployment_generation"], "owner": menv["owner"]},
    "create", worker=worker9, item={"task": "wedged", "task_generation": "gen-w"})
with module.controller_lock(menv):
    state = module.load_state(menv)
    state["pending_actions"]["9"] = wedged
    module.save_state(menv, state)

run("request", "--task", "task-1", "--task-generation", "gen-1",
    "--home-binding", binding(1001), "--account-binding", binding(2001),
    "--worktree-binding", binding(3001), "--repository-binding", binding(4001),
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible")
result = run("reconcile", "--apply", "--json", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
output = json.loads(result.stdout)
kinds = [action["type"] for action in output["actions"]]
assert "create" in kinds, kinds
assert "replay-refused" in kinds, kinds
refused = [action for action in output["actions"] if action["type"] == "replay-refused"]
assert refused[0]["slot"] == 9, refused

state = json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())
assert "9" in state["pending_actions"], "the wedged claim was silently dropped"
assert "1" in state["workers"], "the fleet did not converge past the wedge"
assert state["queue"]["task-1@gen-1"]["status"] == "assigned"

# The planner must never plan a mutation for a claimed slot: a released
# worker's destruction sequence waits while a claim owns the slot, because
# the durable record mid-mutation is deliberately not yet the truth.
with module.controller_lock(menv):
    held = module.load_state(menv)
    worker1 = held["workers"]["1"]
    worker1["release_proof"] = {"schema": "fm.worker-release/v2", "proof_digest": "a" * 64}
    worker1["released_at"] = module.iso_utc()
    claim1 = module.make_action(
        {"deployment_generation": menv["deployment_generation"], "owner": menv["owner"]},
        "steer", worker=worker1, request_digest="b" * 64)
    held["pending_actions"]["1"] = claim1
    module.save_state(menv, held)
plan = json.loads(run("reconcile", "--json").stdout)
planned_slots = [entry.get("slot") for entry in plan["actions"] if entry["type"] not in ("admission-refused", "replay-refused")]
assert 1 not in planned_slots, (
    "the planner proposed a mutation for a slot an unapplied claim owns", plan["actions"])

# strict drain RAISES on the wedged claim instead of recording and moving on:
# resume depends on exactly this to refuse resuming over unapplied state.
strict_raised = None
try:
    module.drain_pending(menv, slot="9", strict=True)
except module.LifecycleError as exc:
    strict_raised = exc
assert strict_raised is not None, "a strict drain swallowed a wedged claim's refusal"
PY
  pass "a wedged slot's claim is reported and retained while the rest of the fleet converges"
}


static_contract
classification_and_admission_matrix
azure_provider_refusal_matrix
end_to_end_lifecycle
shared_specialized_cli
shared_shape_cli
landing_authority_refresh
endpoint_authority_checkout_helper
account_authority_real_helper
restart_idempotency
partial_apply_never_persists
surrender_lane
surrender_refuses_when_ordinary_authority_passes
surrender_refusal_matrix
legacy_scalar_migration
state_fence_and_revision_cas
concurrent_mutations_do_not_serialize
wedged_slot_does_not_stop_the_fleet

echo "# fm-worker-lifecycle.test.sh: all assertions passed"
