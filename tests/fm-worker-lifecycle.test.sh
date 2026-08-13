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
for marker in (
    '"assigned", "clean-warm", "deallocated", "orphaned-safe-to-delete", "retained-for-investigation"',
    "REGIONAL_ADMISSION_CEILING_VCPUS = 128", "AUTHOR_PLAN_VCPUS = MAX_WORKERS * VCPUS_PER_WORKER",
    "SPECIALIZED_SHAPE_VCPUS = 40", "SHARED_HEADROOM_VCPUS = 22", "MAX_WORKERS = 16",
    'FM_AZURE_WORKER_WARM_IDLE currently must remain zero', "pending_action",
    "capacity-reserve", "capacity-reserve-shape", "capacity-release", "merged_specialized_reservations",
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
# Bootstrap-only untrained-forecast seam: the exact Cost Management
# insufficient-training-data refusal may substitute the readable actual as the
# conservative forecast, but only in commissioning phase with the operator's
# explicit confirmation; every other unreadable shape still refuses.
untrained = copy.deepcopy(inventory)
untrained["metrics"]["forecast_usd"] = None
untrained["metrics"]["forecast_untrained"] = True
assert module.admission_result(env, state, untrained, 1, item)[0] is False
os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"] = "1"
try:
    assert module.admission_result(env, state, untrained, 1, item)[0] is True
    plain_unreadable = copy.deepcopy(inventory)
    plain_unreadable["metrics"]["forecast_usd"] = None
    assert module.admission_result(env, state, plain_unreadable, 1, item)[0] is False
    no_actual = copy.deepcopy(untrained)
    no_actual["metrics"]["actual_usd"] = None
    assert module.admission_result(env, state, no_actual, 1, item)[0] is False
finally:
    del os.environ["FM_AZURE_WORKER_ALLOW_UNTRAINED_FORECAST"]
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
try:
    module.specialized_capacity_inventory(controller, [specialized_vm], [])
except module.ProviderError as exc:
    assert "no exact durable reservation" in str(exc)
else:
    raise AssertionError("active specialized VM without reservation was accepted")
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

# Ordinary resources require conditional ETags; exact role assignments use
# their principal/role immutable pair because Azure may omit an ETag there.
calls = []
module.az = lambda controller_arg, args, check=False: calls.append(args) or ({}, 0, "")
try:
    module.conditional_delete(controller, "task-disk", {"id": "/disk", "etag": None})
except module.ProviderError as exc:
    assert "ETag" in str(exc)
else:
    raise AssertionError("unfenced task-disk deletion accepted")
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

path = Path(os.environ["FIXTURE_STATE"])
request = json.load(sys.stdin)
controller = request["controller"]
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
    state["calls"].append({"type": action["type"], "slot": action["slot"], "key": key})
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
for number in range(1, 5):
    request(number)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
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
with module.controller_lock(env):
    state = module.load_state(env)
    state["queue"][module.request_key(item["task"], item["task_generation"])] = item
    inventory = module.provider_call(env, "inventory")["inventory"]
    action = module.next_reconcile_action(env, state, inventory)
    state["pending_action"] = action
    module.save_state(env, state)
    # The provider completed, but the controller process is modeled as dying
    # before it durably applied the response.
    module.provider_call(env, "mutate", action)

with module.controller_lock(env):
    restarted = module.load_state(env)
    assert restarted["pending_action"]["idempotency_key"] == action["idempotency_key"]
    assert module.replay_pending(env, restarted) is True
    assert restarted["pending_action"] is None
    assert len(restarted["workers"]) == 1
fixture = json.loads(Path(os.environ["FIXTURE_STATE"]).read_text())
matching = [call for call in fixture["calls"] if call["key"] == action["idempotency_key"]]
assert len(matching) == 2
assert len(fixture["seen"]) == 1 and len(fixture["workers"]) == 1
PY
  pass "restart replays one exact idempotency key without duplicating assignment"
}

static_contract
classification_and_admission_matrix
azure_provider_refusal_matrix
end_to_end_lifecycle
shared_specialized_cli
shared_shape_cli
landing_authority_refresh
restart_idempotency

echo "# fm-worker-lifecycle.test.sh: all assertions passed"
