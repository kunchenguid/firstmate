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

service_complete_front_door() {
  local tmp help
  fm_test_tmproot_into tmp fm-worker-service-complete-front-door
  mkdir -p "$tmp/home"
  help=$(FM_HOME="$tmp/home" "$WRAPPER" service-complete --help) \
    || fail "supported lifecycle wrapper rejected service-complete"
  case "$help" in
    *--request-digest*--confirm-subscription*) ;;
    *) fail "service-complete help lost its exact execution binding" ;;
  esac
  pass "supported lifecycle wrapper exposes service-complete"
}

service_complete_replay_contract() {
  python3 - "$CONTROLLER" <<'PY' || fail "service completion replay contract failed"
import contextlib
import copy
import importlib.util
from types import SimpleNamespace
import sys

spec = importlib.util.spec_from_file_location("lifecycle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

bindings = {
    "home_binding": "1" * 64,
    "task": "service-task",
    "task_generation": "service-generation",
    "assignment_generation": "asg-00000001",
    "account_binding": "2" * 64,
    "worktree_binding": "3" * 64,
    "repository_binding": "4" * 64,
    "repository_generation": "repository-generation",
}
request_digest = "5" * 64
result_digest = "6" * 64
item = {
    **bindings,
    "role": "no-mistakes",
    "status": "assigned",
    "slot": 1,
}
worker = {
    "role": "no-mistakes",
    "queue_key": "service-task@service-generation",
    "assignment_generation": bindings["assignment_generation"],
    "bindings": bindings,
    "cloud_instance_id": "worker-instance",
    "resources": {"vm": {"id": "/exact/vm"}},
    "last_execution_digest": result_digest,
    "release_proof": None,
}
execution = {
    "request_digest": request_digest,
    "result_digest": result_digest,
    "assignment_generation": bindings["assignment_generation"],
}
state = {
    "queue": {"service-task@service-generation": item},
    "workers": {"1": worker},
    "executions": {request_digest: execution},
}
module.controller_lock = lambda _env: contextlib.nullcontext()
module.load_state = lambda _env: state
module.save_state = lambda _env, _state: None
args = SimpleNamespace(
    task="service-task",
    task_generation="service-generation",
    assignment_generation=bindings["assignment_generation"],
    request_digest=request_digest,
    confirm_subscription="subscription",
)
env = {"subscription": "subscription"}

# Crash window one: the first call durably moved the item to releasing, but
# the caller died before observing success. The exact retry is idempotent.
module.command_service_complete(env, args)
assert item["status"] == "releasing", item
assert item["service_completion_receipt"] == worker["release_proof"], item
module.command_service_complete(env, args)

# Crash window two: reconcile completed the reset and removed the worker, but
# the caller died before publishing the cached result. The queue-owned exact
# receipt survives reset and admits only the same bound completion request.
item["status"] = "complete"
# The released slot may already belong to a later task. Its presence cannot
# invalidate the old queue item's exact, self-digested completion receipt.
replacement_worker = {
    "queue_key": "later-task@later-generation",
    "role": "author",
    "assignment_generation": "asg-00000002",
    "release_proof": None,
}
state["workers"] = {"1": replacement_worker}
replacement_before = copy.deepcopy(replacement_worker)
module.command_service_complete(env, args)
assert replacement_worker == replacement_before, replacement_worker
wrong = SimpleNamespace(**vars(args))
wrong.assignment_generation = "asg-99999999"
try:
    module.command_service_complete(env, wrong)
except module.LifecycleError as exc:
    assert "identity differs" in str(exc), exc
else:
    raise AssertionError("completed service receipt admitted a foreign assignment")

# The provider-side regression below emits this exact terminal shape. Prove
# the lifecycle consumer recognizes it as terminal (rather than malformed),
# fails closed, and leaves the durable execute claim available for explicit
# abandonment/recovery.
terminal_action = {
    "type": "execute",
    "slot": 1,
    "request_digest": "7" * 64,
    "idempotency_key": "8" * 64,
    "resources": {"task-command": {"id": "/exact/task-command"}},
}
terminal_state = {
    "queue": {"terminal-task@terminal-generation": {"status": "assigned"}},
    "workers": {"1": {"queue_key": "terminal-task@terminal-generation"}},
    "executions": {},
    "pending_actions": {"1": terminal_action},
    "completed_worker_seconds": 0.0,
}
state = terminal_state
terminal_result = {"execution": {
    "schema": "fm.worker-execution-terminal/v1",
    "request_digest": terminal_action["request_digest"],
    "idempotency_key": terminal_action["idempotency_key"],
    "disposition": "provider-terminal",
    "provisioning_state": "Succeeded",
    "execution_state": "Failed",
    "exit_code": 2,
    "task_command_id": "/exact/task-command",
}}
try:
    module.apply_pending(env, terminal_action, terminal_result)
except module.LifecycleError as exc:
    assert "provider-terminal" in str(exc) and "failed" in str(exc), exc
else:
    raise AssertionError("failed guest execution was applied as a successful result")
assert terminal_state["pending_actions"]["1"] == terminal_action, terminal_state
PY
  pass "service completion replays across releasing and completed crash windows"
}

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
    "ProviderIdentityRefused", "fm.worker-execution-terminal/v1",
    "capacity-reserve", "capacity-reserve-shape", "capacity-release", "capacity-retire-fence",
    "retired_capacity_fences", "merged_specialized_reservations",
    "command_withdraw", "command_surrender", "WORKER AUTHORITY REFUSED",
    "--confirm-discard-unlanded",
    "REVIEWED_CONTROL_SKU_FAMILY", "command_capacity_reserve_shape",
    "fm.worker-authority/v1", "authority-receipt", "fm.worker-execution/v1",
    "roll_daily_baseline", "daily_bound_refusal", "idle_deallocate_due",
    "daily_cost_baseline", "FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE", "idle_deallocated_at",
    "record_daily_override_use", "last_steer_at",
    "CLOUD_ACCOUNT_MIN_HEADROOM_SECONDS", "credential_usable_through",
    "placement_projection_binding", "write_placement_snapshot",
    "cleanup_placement_projection", "profile_active_load",
    "--confirm-orphan-children", "reparented_to", "orphaned_children",
    "compartment_projection",
    "command_compartment_chain_tip", "verified_chain_tip", "refuses to rewind",
    # The compartment monitor CLASSIFIES this command's refusals by their text
    # (bin/fm-secondmate-cloud-monitor.py): the two fork markers freeze the
    # relay lane, the released marker closes it. Editing this command and
    # running only its owning suite must give that signal locally rather than
    # leaving it to the cross-suite CI run.
    "already recorded a different digest",
    "released work cannot record a compartment chain tip",
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
    "ProviderIdentityRefusal", "fm.worker-execution-terminal/v1",
    "build_execute_script", "REFUSED-IDENTITY",
    "worker NIC has a public IP relation", "VM cloud identity set is not exactly one slot identity",
):
    assert marker in azure, marker
for marker in ("fm.worker-execution/v1", "request_digest", "subprocess.run", "MAX_OUTPUT_BYTES"):
    assert marker in supervisor, marker
for marker in ("endpoint_evidence", "report_evidence", "landing_evidence", "account_evidence", "worktree_evidence"):
    assert marker in authority, marker
for marker in (
    # The PR-6 compartment evidence mode: same five receipt names, secondmate
    # semantics, gated on the CONTROLLER-OWNED worker role (never the local
    # task metadata's kind alone), with the mailbox bound to the durable
    # monitor state and the home head tethered to the assignment lineage.
    "secondmate_report_evidence", "secondmate_landing_evidence",
    "secondmate_worktree_evidence", "SECONDMATE_TERMINAL_ACKS",
    'worker_role = worker.get("role", "author")',
    'if worker_role == "secondmate":',
    "compartment evidence is refused", "ordinary evidence is refused",
    "a rewound or truncated outbox", "os.path.lexists",
    "--untracked-files=all",
    # The compartment chain is verified BY CONTENT, and malformed durable
    # state refuses instead of coercing to a permissive zero.
    "secondmate_verified_chain", "secondmate_chain_extent",
    "content differs from its content", "the recomputed chain at sequence",
    "secondmate_report_sections",
    # The landing anchor is CONTROLLER-owned; monitor-local state may never
    # supply it, and its absence refuses rather than being inferred.
    'worker.get("verified_chain_tip")', "carries no verified",
    "controller-owned verified chain tip is malformed",
    # Landing is PROVEN by reachability; landed_bundles is advisory only.
    "secondmate_prove_landed", "merge-base", "--is-ancestor",
    "bundle", "list-heads", "is not reachable from the home worktree head",
    "cannot prove bundle",
):
    assert marker in authority, marker
assert 'state.get("verified_tip")' not in authority, (
    "the landing anchor must not come from monitor-local durable state")
# The compartment worktree receipt must not be laxer than the ordinary one.
assert '"--untracked-files=no"' not in authority
for marker in (
    "sixteen 4-vCPU workers", "$1,500", "3,500 aggregate author worker-hours",
    "downloaded self-contained form artifact", "returns through a file",
    "Combined author and specialized demand beyond the shared 128-vCPU ceiling remains queued",
    "max(Azure observed usage, exact active fleet vCPUs)",
    "commissioning path no longer bypasses cumulative actual or forecast admission",
    "No capacity reservation creates an always-on worker pool",
    "Every acceptance leg needs a positive control", "warm-idle target is zero",
    "FM_AZURE_WORKER_DAILY_BOUND_USD",
    "idle-deallocate stops compute cost unattended; the ordinary release stays human-driven",
    "backstop on RECORDED spend",
    "an ungated reserve lane could quietly burn past the bound",
    "no power-on lane exists",
    "least-active usable profile", "assignment-private projection",
    "maximum of sixteen", "`fireworks-glm`",
    "consume no worker slot and no Codex/Pi worker profile",
):
    assert marker in doc, marker
assert "hosted form service" in doc and "force-delete" in doc
for marker in (
    "--confirm-orphan-children", "reparented_to: primary",
    "verify_release_against_worker", "children-quiesced",
    "chained close ack", "BY CONTENT", "compartment-chain-tip",
    "REACHABILITY", "unverified ATTESTATION", "ADVISORY and never decides",
    "monitor-local state may never supply it",
):
    assert marker in doc, marker
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

# Run commands and staging blobs are per-execution transport: their identities
# change after an execute and must not wedge classification, while every other
# kind still fences on identity (the task-disk case above).
executed = copy.deepcopy(cloud)
executed["resources"]["task-command"]["immutable_id"] = "post-execute-state"
executed["resources"]["task-command"]["provisioning_state"] = "Failed"
executed["resources"]["staging-request"]["immutable_id"] = "post-execute-etag"
executed["resources"]["staging-result"]["immutable_id"] = "post-execute-etag-2"
assert module.classify_worker(worker, executed)[0] == "assigned"
# Azure legitimately changes child provisioning state after VM deallocation.
# The exact ARM ID remains the identity; a mutable Succeeded -> Updating value
# must not strand the worker as an identity mismatch.
transitioned = copy.deepcopy(cloud)
for kind in ("monitor-extension", "bootstrap-command", "ttl-schedule"):
    transitioned["resources"][kind]["immutable_id"] = "Updating"
transitioned["resources"]["monitor-extension"]["provisioning_state"] = "Updating"
assert module.resources_exact(worker, transitioned)[0] is True
# State-container metadata writes legitimately replace the ETag recorded by
# older workers. Canonical inventory identifies the exact container by its ARM
# path, so that one migration shape remains exact while arbitrary identities
# and changed paths below still fail closed.
metadata_updated = copy.deepcopy(cloud)
metadata_updated["resources"]["state-container"]["immutable_id"] = (
    metadata_updated["resources"]["state-container"]["id"]
)
assert module.resources_exact(worker, metadata_updated)[0] is True
foreign_child = copy.deepcopy(transitioned)
foreign_child["resources"]["monitor-extension"]["id"] = "/foreign/monitor-extension"
exact, reason = module.resources_exact(worker, foreign_child)
assert exact is False and "monitor-extension resource ID changed" in reason, reason
for kind in module.REQUIRED_RESOURCE_KINDS:
    changed = copy.deepcopy(cloud)
    changed["resources"][kind]["immutable_id"] = "foreign-" + kind
    classification = module.classify_worker(worker, changed)[0]
    if kind in module.MUTABLE_PROVISIONING_CHILD_KINDS or kind in (
        "staging-request", "staging-result",
    ):
        assert classification == "assigned", (kind, classification)
    else:
        assert classification == "retained-for-investigation", (kind, classification)
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

# Reusable upstream identity is expected, while assignment-private projection
# and worktree ownership remain exclusive.
existing = next(iter(state["queue"].values()))
module.ensure_unique_bindings(state, dict(
    item, task="other", account_binding=existing["account_binding"], worktree_binding="9" * 64
))
existing["account_projection_binding"] = "a" * 64
existing["account_home"] = "/tmp/assignment-a"
try:
    module.ensure_unique_bindings(state, dict(
        item, task="other", account_binding=existing["account_binding"],
        account_projection_binding=existing["account_projection_binding"],
        account_home=existing["account_home"], worktree_binding="9" * 64,
    ))
except module.LifecycleError as exc:
    assert "assignment-private provider projection" in str(exc)
else:
    raise AssertionError("shared assignment-private projection was accepted")
try:
    module.ensure_unique_bindings(state, dict(
        item, task="other", account_binding="9" * 64, worktree_binding=existing["worktree_binding"]
    ))
except module.LifecycleError as exc:
    assert "worktree" in str(exc)
else:
    raise AssertionError("shared writable worktree was accepted")
PY
  pass "reconciliation admits reusable account identity while preserving capacity, projection, and worktree isolation"
}

azure_provider_refusal_matrix() {
  python3 - "$AZURE" <<'PY' || fail "Azure provider refusal matrix failed"
import copy
import hashlib
import importlib.util
import inspect
import json
import subprocess
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

# A child may disappear after its list response while another exact cleanup
# removes it. Only Azure's explicit ResourceNotFound is a truthful absence;
# every other read failure and malformed success remains fail-closed.
original_az = module.az
module.az = lambda *_args, **_kwargs: (
    None, 3,
    "ERROR: (ResourceNotFound) child disappeared\nCode: ResourceNotFound\n",
)
assert module.show_full(controller, "/child", inventory_missing_ok=True) is None
try:
    module.show_full(controller, "/child")
except module.ProviderError as exc:
    assert "ResourceNotFound" in str(exc), exc
else:
    raise AssertionError("non-inventory child read softened ResourceNotFound")
module.az = lambda *_args, **_kwargs: (None, 3, "ERROR: (AuthorizationFailed) denied")
try:
    module.show_full(controller, "/child")
except module.ProviderError as exc:
    assert "AuthorizationFailed" in str(exc), exc
else:
    raise AssertionError("child inventory softened a non-absence provider error")
module.az = lambda *_args, **_kwargs: ([], 0, "")
try:
    module.show_full(controller, "/child")
except module.ProviderError as exc:
    assert "malformed" in str(exc), exc
else:
    raise AssertionError("child inventory accepted a malformed successful read")
module.az = original_az
inventory_source = inspect.getsource(module.inventory)
assert inventory_source.count("if value is None:") == 3
assert "transient_not_found_attempts=4" in inventory_source

# Azure CLI can fail `vm list --show-details` when a VM disappears during its
# internal instance-view expansion. Only the explicitly opted-in list retries
# explicit ResourceNotFound, and the retry count stays bounded.
missing = "ERROR: (ResourceNotFound) VM disappeared\nCode: ResourceNotFound\n"
calls = []
responses = iter(((None, 3, missing), ([], 0, "")))
original_sleep = module.time.sleep
module.time.sleep = lambda _seconds: None
module.az = lambda *_args, **_kwargs: calls.append(True) or next(responses)
assert module.list_json(
    controller, ["vm", "list", "--show-details"], transient_not_found_attempts=2,
) == []
assert len(calls) == 2, calls
calls.clear()
module.az = lambda *_args, **_kwargs: calls.append(True) or (None, 3, missing)
try:
    module.list_json(controller, ["vm", "list", "--show-details"])
except module.ProviderError as exc:
    assert "ResourceNotFound" in str(exc), exc
else:
    raise AssertionError("default list inventory retried or softened ResourceNotFound")
assert len(calls) == 1, calls
calls.clear()
module.az = lambda *_args, **_kwargs: calls.append(True) or (
    None, 3, "ERROR: (AuthorizationFailed) denied",
)
try:
    module.list_json(
        controller, ["vm", "list", "--show-details"], transient_not_found_attempts=4,
    )
except module.ProviderError as exc:
    assert "AuthorizationFailed" in str(exc), exc
else:
    raise AssertionError("list inventory retried a non-absence provider error")
assert len(calls) == 1, calls
module.az = lambda *_args, **_kwargs: ({}, 0, "")
try:
    module.list_json(
        controller, ["vm", "list", "--show-details"], transient_not_found_attempts=4,
    )
except module.ProviderError as exc:
    assert "malformed" in str(exc), exc
else:
    raise AssertionError("list inventory retried a malformed successful read")
module.az = original_az
module.time.sleep = original_sleep

# Replacement compute advances the worker generation without rewriting the
# durable slot reservation. Cleanup accepts only that reservation's canonical
# older generation; every other resource and ownership tag remains exact.
cleanup_action = copy.deepcopy(action)
cleanup_action["cloud_generation"] = 3
cleanup_tags = module.action_tags(controller, cleanup_action)
cleanup_worker = copy.deepcopy(worker)
for value in cleanup_worker["resources"].values():
    value["tags"] = dict(cleanup_tags)
cleanup_worker["resources"]["global-reservation"]["tags"]["cloud-generation"] = "1"
try:
    module.recorded_exact(cleanup_action, cleanup_worker)
except module.ProviderError as exc:
    assert "global-reservation" in str(exc) and "cloud-generation" in str(exc), exc
else:
    raise AssertionError("ordinary exactness accepted an older reservation generation")
module.cleanup_recorded_exact(cleanup_action, cleanup_worker)
for invalid in ("0", "01", "4", "foreign"):
    changed = copy.deepcopy(cleanup_worker)
    changed["resources"]["global-reservation"]["tags"]["cloud-generation"] = invalid
    try:
        module.cleanup_recorded_exact(cleanup_action, changed)
    except module.ProviderError as exc:
        assert "cloud-generation" in str(exc), exc
    else:
        raise AssertionError("cleanup accepted invalid reservation generation {!r}".format(invalid))
changed = copy.deepcopy(cleanup_worker)
changed["resources"]["task-disk"]["tags"]["cloud-generation"] = "1"
try:
    module.cleanup_recorded_exact(cleanup_action, changed)
except module.ProviderError as exc:
    assert "task-disk" in str(exc) and "cloud-generation" in str(exc), exc
else:
    raise AssertionError("cleanup widened the generation exception beyond the reservation")
changed = copy.deepcopy(cleanup_worker)
changed["resources"]["global-reservation"]["tags"]["task-binding"] = "foreign"
try:
    module.cleanup_recorded_exact(cleanup_action, changed)
except module.ProviderError as exc:
    assert "task-binding" in str(exc), exc
else:
    raise AssertionError("cleanup accepted a foreign reservation ownership binding")
for missing in ("cloud-generation", "task-binding"):
    changed = copy.deepcopy(cleanup_worker)
    changed["resources"]["global-reservation"]["tags"].pop(missing)
    try:
        module.cleanup_recorded_exact(cleanup_action, changed)
    except module.ProviderError as exc:
        assert missing in str(exc) and "absent" in str(exc), exc
    else:
        raise AssertionError("cleanup accepted a reservation missing {}".format(missing))
for cleanup_name in ("mutate_deallocate", "mutate_delete_compute", "mutate_reset"):
    cleanup_source = inspect.getsource(getattr(module, cleanup_name))
    assert "cleanup_recorded_exact(" in cleanup_source, cleanup_name
# Compute-child ARM IDs are stable across mutable provisioningState changes;
# preserve compatibility with a live assignment recorded before this fix,
# whose legacy immutable_id contains the old Succeeded value.
for kind in module.MUTABLE_PROVISIONING_CHILD_KINDS:
    succeeded = {
        "id": resources[kind]["id"],
        "properties": {"provisioningState": "Succeeded"},
    }
    updating = copy.deepcopy(succeeded)
    updating["properties"]["provisioningState"] = "Updating"
    assert module.immutable_id(kind, succeeded) == resources[kind]["id"]
    assert module.immutable_id(kind, updating) == resources[kind]["id"]

transitioned = copy.deepcopy(worker)
transitioned["resources"]["monitor-extension"]["immutable_id"] = "Updating"
transitioned["resources"]["monitor-extension"]["provisioning_state"] = "Updating"
try:
    module.recorded_exact(action, transitioned)
except module.ProviderError as exc:
    assert not isinstance(exc, module.ProviderIdentityRefusal), exc
    assert "provisioning state" in str(exc), exc
else:
    raise AssertionError("ready-child admission accepted an Updating monitor extension")
module.recorded_exact(action, transitioned, require_ready_children=False)
foreign_child_tags = copy.deepcopy(transitioned)
foreign_child_tags["resources"]["monitor-extension"]["tags"]["task-binding"] = "foreign"
try:
    module.recorded_exact(action, foreign_child_tags, require_ready_children=False)
except module.ProviderError as exc:
    assert "task-binding" in str(exc), exc
else:
    raise AssertionError("cleanup accepted foreign monitor-extension ownership tags")

# The surrender cleanup shape is a deallocated exact VM whose monitor child
# moved Succeeded -> Updating. Cleanup must proceed, while a foreign child ID
# remains a permanent identity refusal.
deallocated_transition = copy.deepcopy(transitioned)
deallocated_transition["resources"]["vm"]["power_state"] = "VM deallocated"
original_inventory = module.inventory
module.inventory = lambda controller_arg, include_metrics=False: {
    "workers": [deallocated_transition], "conflicts": [], "metrics": {},
}
assert module.mutate_deallocate(controller, action) == deallocated_transition
foreign_transition = copy.deepcopy(deallocated_transition)
foreign_transition["resources"]["monitor-extension"]["id"] = "/foreign/monitor-extension"
module.inventory = lambda controller_arg, include_metrics=False: {
    "workers": [foreign_transition], "conflicts": [], "metrics": {},
}
try:
    module.mutate_deallocate(controller, action)
except module.ProviderIdentityRefusal as exc:
    assert "resource ID differs" in str(exc), exc
else:
    raise AssertionError("deallocate cleanup accepted a foreign monitor-extension ID")
module.inventory = original_inventory
# Ordinary provider failures stay on exit 2. If every ProviderError were
# mislabeled as a permanent identity refusal, abandon-claim could clear a
# transiently failed claim.
plain_refusal = subprocess.run(
    [sys.executable, sys.argv[1]], input=b"{}\n",
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert plain_refusal.returncode == 2, plain_refusal
assert b"AZURE WORKER PROVIDER REFUSED:" in plain_refusal.stderr, plain_refusal.stderr
assert b"REFUSED-IDENTITY" not in plain_refusal.stderr, plain_refusal.stderr
for child in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
    changed = copy.deepcopy(worker)
    changed["resources"][child]["attached_to"] = "/foreign-vm"
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError as exc:
        assert "exact worker VM" in str(exc)
        assert not isinstance(exc, module.ProviderIdentityRefusal), exc
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
    if kind in module.MUTABLE_PROVISIONING_CHILD_KINDS or kind in (
        "staging-request", "staging-result",
    ):
        # Mutable child state and execute/blob transport identity are not an
        # ownership fence; their exact resource path remains one.
        module.recorded_exact(action, changed)
        moved = copy.deepcopy(worker)
        moved["resources"][kind]["id"] = "/slot/1/elsewhere"
        try:
            module.recorded_exact(action, moved)
        except module.ProviderIdentityRefusal:
            pass
        else:
            raise AssertionError("relocated {} transport path accepted".format(kind))
        continue
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError as exc:
        assert isinstance(exc, module.ProviderIdentityRefusal), exc
    else:
        raise AssertionError("foreign {} immutable identity accepted".format(kind))
changed = copy.deepcopy(worker)
changed["resources"]["task-command"]["immutable_id"] = "post-execute-state"
changed["resources"]["task-command"]["provisioning_state"] = "Failed"
module.recorded_exact(action, changed)
for kind in ("bootstrap-command", "monitor-extension"):
    changed = copy.deepcopy(worker)
    changed["resources"][kind]["provisioning_state"] = "Failed"
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError as exc:
        assert "provisioning state" in str(exc), exc
    else:
        raise AssertionError("failed {} provisioning state accepted".format(kind))
for key in tags:
    changed = copy.deepcopy(worker)
    changed["resources"]["task-disk"]["tags"][key] = "foreign"
    try:
        module.recorded_exact(action, changed)
    except module.ProviderError as exc:
        assert not isinstance(exc, module.ProviderIdentityRefusal), exc
    else:
        raise AssertionError("foreign task-disk tag accepted: {}".format(key))

# A terminal probe is bound to the exact execute script (or its exact request
# digest plus assignment-generation line), recovers a completed real result,
# and never converts an unrelated stale Failed Run Command into finality.
execute_action = copy.deepcopy(action)
execute_action["type"] = "execute"
execute_action["request_digest"] = "5" * 64
execute_action["idempotency_key"] = "6" * 64
execute_action["request"] = dict(execute_action["bindings"], **{
    "schema": "fm.worker-execution/v1",
    "cloud_instance_id": execute_action["cloud_instance_id"],
    "argv": ["/usr/bin/true"], "wall_seconds": 60,
    "request_digest": execute_action["request_digest"],
})
script = module.build_execute_script(execute_action)
task_command = worker["resources"]["task-command"]
real_show_full = module.show_full
real_run_command_instance_view = module.run_command_instance_view
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": {"script": script}, "provisioningState": "Failed"}
}
terminal_kind, terminal = module.execute_terminal_disposition(
    controller, execute_action, worker["resources"]
)
assert terminal_kind == module.EXECUTE_DISPOSITION_TERMINAL, terminal_kind
assert terminal == {
    "schema": "fm.worker-execution-terminal/v1",
    "request_digest": execute_action["request_digest"],
    "idempotency_key": execute_action["idempotency_key"],
    "disposition": "provider-terminal",
    "provisioning_state": "Failed",
    "task_command_id": task_command["id"],
}, terminal
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": {"script": "# normalized by Azure\n" + script},
                   "provisioningState": "Canceled"}
}
fallback_kind, fallback_terminal = module.execute_terminal_disposition(
    controller, execute_action, worker["resources"]
)
assert fallback_kind == module.EXECUTE_DISPOSITION_TERMINAL, fallback_kind
assert fallback_terminal["disposition"] == "provider-terminal", fallback_terminal
stale_script = script.replace(execute_action["request_digest"], "9" * 64)
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": {"script": stale_script}, "provisioningState": "Failed"}
}
assert module.execute_terminal_disposition(controller, execute_action, worker["resources"]) == (
    module.EXECUTE_DISPOSITION_SUBMIT, None
)
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": {"script": "echo unrelated"}, "provisioningState": "Failed"}
}
assert module.execute_terminal_disposition(controller, execute_action, worker["resources"]) == (
    module.EXECUTE_DISPOSITION_SUBMIT, None
)
execution = {
    "schema": "fm.worker-execution-result/v1",
    "request_digest": execute_action["request_digest"],
    "task": "task", "task_generation": "task-gen",
    "assignment_generation": "asg-00000001", "cloud_instance_id": "vm-instance",
    "repository_binding": "4" * 64, "repository_generation": "repo-gen",
    "exit_code": 0, "timed_out": False,
    "stdout_sha256": "7" * 64, "stderr_sha256": "8" * 64,
    "stdout_truncated": False, "stderr_truncated": False,
}
execution["result_digest"] = hashlib.sha256(module.canonical_bytes(execution)).hexdigest()
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"source": {"script": script}, "provisioningState": "Succeeded"}
}
module.run_command_instance_view = lambda *_args, **_kwargs: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(execution, sort_keys=True, separators=(",", ":")),
    "error": "",
}
recovered_kind, recovered_execution = module.execute_terminal_disposition(
    controller, execute_action, worker["resources"]
)
assert recovered_kind == module.EXECUTE_DISPOSITION_RECOVERED, recovered_kind
assert recovered_execution == execution, recovered_execution
module.run_command_instance_view = lambda *_args, **_kwargs: {
    "executionState": "Failed", "exitCode": 2, "output": "", "error": "guest failed",
}
failed_kind, failed_execution = module.execute_terminal_disposition(
    controller, execute_action, worker["resources"]
)
assert failed_kind == module.EXECUTE_DISPOSITION_TERMINAL, failed_kind
assert failed_execution == {
    "schema": "fm.worker-execution-terminal/v1",
    "request_digest": execute_action["request_digest"],
    "idempotency_key": execute_action["idempotency_key"],
    "disposition": "provider-terminal",
    "provisioning_state": "Succeeded",
    "execution_state": "Failed",
    "exit_code": 2,
    "task_command_id": task_command["id"],
}, failed_execution

# Once the exact request owns the Run Command, a replay may only recover its
# terminal disposition or exact result. Updating/Running and a Succeeded
# command without a valid marker/digest are ordinary retryable refusals; they
# must never fall through to the update that would execute the guest twice.
real_inventory = module.inventory
real_worker_by_slot = module.worker_by_slot
real_recorded_exact = module.recorded_exact
real_upload_json_blob = module.upload_json_blob
real_az = module.az
module.inventory = lambda *_args, **_kwargs: {"workers": [worker]}
module.worker_by_slot = lambda _snapshot, _slot: worker
active_resources = {"value": worker["resources"]}
module.recorded_exact = lambda _action, _worker: active_resources["value"]
updates = []
def forbidden_update(*_args, **_kwargs):
    updates.append("update")
    raise AssertionError("exact-bound execution reached Run Command update")
module.upload_json_blob = forbidden_update
module.az = forbidden_update

def retained_execute(properties, view=None):
    module.show_full = lambda *_args, **_kwargs: {"properties": properties}
    module.run_command_instance_view = lambda *_args, **_kwargs: dict(view or {})
    try:
        module.mutate_execute(controller, execute_action)
    except module.ProviderError:
        pass
    else:
        raise AssertionError("exact-bound incomplete execution was submitted again")
    assert updates == [], updates

retained_execute({"provisioningState": "Succeeded"})
retained_execute({"source": {"script": None}, "provisioningState": "Succeeded"})
retained_execute({"source": {"script": ""}, "provisioningState": "Succeeded"})
retained_execute({"source": {"script": " \n\t"}, "provisioningState": "Succeeded"})
retained_execute(
    {
        "tags": {
            module.EXECUTION_REQUEST_TAG: execute_action["request_digest"],
            module.EXECUTION_IDEMPOTENCY_TAG: execute_action["idempotency_key"],
        },
        "provisioningState": "Succeeded",
    },
    {"executionState": "Succeeded", "output": "", "error": ""},
)
retained_execute(
    {
        "source": {"script": "echo prior execution"},
        "tags": {
            module.EXECUTION_REQUEST_TAG: "9" * 64,
            module.EXECUTION_IDEMPOTENCY_TAG: "8" * 64,
        },
        "provisioningState": "Succeeded",
    },
    {"executionState": "Succeeded", "output": "", "error": ""},
)
prior_execution = dict(execution, request_digest="9" * 64)
prior_execution.pop("result_digest", None)
prior_execution["result_digest"] = hashlib.sha256(
    module.canonical_bytes(prior_execution)
).hexdigest()
module.show_full = lambda *_args, **_kwargs: {
    "properties": {
        "source": {"script": "echo prior execution"},
        "provisioningState": "Succeeded",
    },
    "tags": {
        module.EXECUTION_REQUEST_TAG: "9" * 64,
        module.EXECUTION_IDEMPOTENCY_TAG: "8" * 64,
    },
}
module.run_command_instance_view = lambda *_args, **_kwargs: {
    "executionState": "Succeeded",
    "output": "FM-WORKER-RESULT:" + json.dumps(
        prior_execution, sort_keys=True, separators=(",", ":")
    ),
    "error": "",
}
assert module.execute_terminal_disposition(
    controller, execute_action, active_resources["value"]
) == (module.EXECUTE_DISPOSITION_SUBMIT, None)
retained_execute(
    {
        "tags": {module.EXECUTION_REQUEST_TAG: execute_action["request_digest"]},
        "provisioningState": "Succeeded",
    }
)
retained_execute({"source": {"script": script}, "provisioningState": "Updating"})
retained_execute(
    {"source": {"script": script}, "provisioningState": "Succeeded"},
    {"executionState": "Running", "output": "", "error": ""},
)
retained_execute(
    {"source": {"script": script}, "provisioningState": "Succeeded"},
    {"executionState": "Succeeded", "output": "", "error": ""},
)
bad_execution = dict(execution, result_digest="0" * 64)
retained_execute(
    {"source": {"script": script}, "provisioningState": "Succeeded"},
    {
        "executionState": "Succeeded",
        "output": "FM-WORKER-RESULT:" + json.dumps(
            bad_execution, sort_keys=True, separators=(",", ":")
        ),
        "error": "",
    },
)

# The exact initial sentinel depends on the same pinned supervisor bytes used
# at worker creation. A missing or unreadable local copy is a bounded provider
# refusal, never an unhandled filesystem exception.
real_root = module.ROOT
class UnreadableRoot:
    def __truediv__(self, _component):
        return self

    def read_bytes(self):
        raise OSError("unreadable-" + "x" * 1000)

module.ROOT = UnreadableRoot()
try:
    module.initial_execute_staging_pair(execute_action)
except module.ProviderError as exc:
    assert str(exc).startswith("exact initial worker supervisor is unreadable: "), exc
    assert len(str(exc)) <= 350, len(str(exc))
else:
    raise AssertionError("unreadable worker supervisor escaped the provider refusal boundary")
finally:
    module.ROOT = real_root

# Azure's actual fresh managed Run Command omits source entirely and exposes
# the async preflight stub as Failed/-202. The exact assignment-captured blob
# ETags prove this is the one initial submission even if the landed supervisor
# changed after create. A staged request changes its ETag before a replay, so
# the accepted update still cannot pass through this initial gate twice.
fresh_resources = copy.deepcopy(worker["resources"])
fresh_resources["staging-request"]["digest"] = "7" * 64
fresh_resources["staging-result"]["digest"] = "8" * 64
crashed_resources = copy.deepcopy(fresh_resources)
crashed_resources["staging-request"]["immutable_id"] = "post-staging-etag"
active_resources["value"] = crashed_resources
retained_execute(
    {"provisioningState": "Succeeded"},
    {"executionState": "Failed", "exitCode": -202, "output": "", "error": ""},
)
active_resources["value"] = fresh_resources
retained_execute(
    {"provisioningState": "Succeeded"},
    {"executionState": "Failed", "exitCode": -201, "output": "", "error": ""},
)

uploaded_json_blobs = []
def record_json_upload(_controller, _storage, _container, blob_name, *_args, **_kwargs):
    uploaded_json_blobs.append(blob_name)
module.upload_json_blob = record_json_upload
views = iter([
    {"executionState": "Failed", "exitCode": -202, "output": "", "error": ""},
    {
        "executionState": "Succeeded", "exitCode": 0,
        "output": "FM-WORKER-RESULT:" + json.dumps(
            execution, sort_keys=True, separators=(",", ":")
        ),
        "error": "",
    },
])
module.show_full = lambda *_args, **_kwargs: {
    "properties": {"provisioningState": "Succeeded"},
    "tags": dict(tags),
}
update_commands = []
def accept_initial_update(_controller, command, **_kwargs):
    update_commands.append(command)
    return {}, 0, ""
module.az = accept_initial_update

# A just-submitted command is held to the same exact schema and digest parser
# used during recovery. A self-digested foreign schema must not be persisted.
wrong_schema_execution = dict(execution, schema="fm.worker-execution-result/v2")
wrong_schema_execution.pop("result_digest", None)
wrong_schema_execution["result_digest"] = hashlib.sha256(
    module.canonical_bytes(wrong_schema_execution)
).hexdigest()
wrong_schema_views = iter([
    {"executionState": "Failed", "exitCode": -202, "output": "", "error": ""},
    {
        "executionState": "Succeeded", "exitCode": 0,
        "output": "FM-WORKER-RESULT:" + json.dumps(
            wrong_schema_execution, sort_keys=True, separators=(",", ":")
        ),
        "error": "",
    },
])
module.run_command_instance_view = lambda *_args, **_kwargs: next(wrong_schema_views)
try:
    module.mutate_execute(controller, execute_action)
except module.ProviderError as exc:
    assert "result marker schema is not exact" in str(exc), exc
else:
    raise AssertionError("wrong-schema submitted execution result was accepted")
assert len(update_commands) == 1, update_commands
assert uploaded_json_blobs == [
    module.expected_names(controller, execute_action["slot"])["staging-request"]
], uploaded_json_blobs

update_commands.clear()
uploaded_json_blobs.clear()
module.run_command_instance_view = lambda *_args, **_kwargs: next(views)
_, admitted_execution = module.mutate_execute(controller, execute_action)
assert admitted_execution == execution, admitted_execution
assert len(update_commands) == 1, update_commands
assert uploaded_json_blobs == [
    module.expected_names(controller, execute_action["slot"])["staging-request"],
    module.expected_names(controller, execute_action["slot"])["staging-result"],
], uploaded_json_blobs
submitted = update_commands[0]
assert "{}={}".format(
    module.EXECUTION_REQUEST_TAG, execute_action["request_digest"]
) in submitted, submitted
assert "{}={}".format(
    module.EXECUTION_IDEMPOTENCY_TAG, execute_action["idempotency_key"]
) in submitted, submitted

updates.clear()
module.upload_json_blob = forbidden_update
module.az = forbidden_update
retained_execute(
    {
        "tags": {
            module.EXECUTION_REQUEST_TAG: execute_action["request_digest"],
            module.EXECUTION_IDEMPOTENCY_TAG: execute_action["idempotency_key"],
        },
        "provisioningState": "Succeeded",
    },
    {"executionState": "Succeeded", "output": "", "error": ""},
)
active_resources["value"] = worker["resources"]
module.inventory = real_inventory
module.worker_by_slot = real_worker_by_slot
module.recorded_exact = real_recorded_exact
module.upload_json_blob = real_upload_json_blob
module.az = real_az
module.show_full = real_show_full
module.run_command_instance_view = real_run_command_instance_view

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
    # Release is an existence poll, not a FIFO read: a FIFO frees only the
    # readers already blocked on it, so a child still between its arrival
    # file and the FIFO open would hang forever past the writer's close.
    import time as _time
    release = Path(barrier_dir) / "release"
    while not release.exists():
        _time.sleep(0.05)

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
        "workers": {}, "seen": {}, "calls": [], "execute_updates": 0,
        "execute_terminal_probes": 0, "initial_stub_admissions": 0,
        "metrics": {"actual_usd": 100.0, "forecast_usd": 150.0},
    }

def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()

def tags(action):
    bindings = action["bindings"]
    if action.get("role") == "secondmate":
        return {
            "workload": "firstmate", "firstmate-role": "secondmate-compartment",
            "deployment-generation": action["deployment_generation"], "cleanup-owner": action["owner"],
            "worker-slot": str(action["slot"]), "home-binding": bindings["home_binding"],
            "task-binding": bindings["task"], "task-generation": bindings["task_generation"],
            "assignment-generation": bindings["assignment_generation"],
            "account-binding": bindings["account_binding"], "worktree-binding": bindings["worktree_binding"],
            "repository-binding": bindings["repository_binding"],
            "repository-generation": bindings["repository_generation"],
            "agent-capacity": "one-home-scoped-secondmate", "nested-team": "forbidden",
            "child-launcher": "absent", "browser-profile": "forbidden",
        }
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
    slot = str(action["slot"])
    kind = action["type"]
    if kind == "execute" and os.environ.get("FIXTURE_TRANSIENT_EXECUTE_REFUSAL"):
        sys.stderr.write("FIXTURE PROVIDER REFUSED: transient execute refusal\n")
        raise SystemExit(2)
    live_worker = state["workers"].get(slot)
    if live_worker is not None:
        live_resources = live_worker.get("resources", {})
        for resource_kind, recorded in (action.get("resources") or {}).items():
            current = live_resources.get(resource_kind)
            if not isinstance(current, dict) or not isinstance(recorded, dict):
                continue
            identity_changed = (
                resource_kind not in ("task-command", "staging-request", "staging-result")
                and current.get("immutable_id") != recorded.get("immutable_id")
            )
            if current.get("id") != recorded.get("id") or identity_changed:
                sys.stderr.write(
                    "AZURE WORKER PROVIDER REFUSED-IDENTITY: {} identity differs from "
                    "the recorded assignment\n".format(resource_kind)
                )
                raise SystemExit(3)
    task_command = (live_worker or {}).get("resources", {}).get("task-command", {})
    if kind == "execute" and os.environ.get("FIXTURE_INITIAL_EXECUTE_STUB"):
        if task_command.get("execution_request_digest") or task_command.get("execution_idempotency_key"):
            sys.stderr.write("FIXTURE PROVIDER REFUSED: initial execute stub is already bound\n")
            raise SystemExit(2)
        state["initial_stub_admissions"] = state.get("initial_stub_admissions", 0) + 1
    if kind == "execute" and os.environ.get("FIXTURE_UNREADABLE_EXECUTE_SCRIPT"):
        state["execute_terminal_probes"] = state.get("execute_terminal_probes", 0) + 1
        save()
        sys.stderr.write(
            "FIXTURE PROVIDER REFUSED: existing worker task Run Command source "
            "script is unreadable\n"
        )
        raise SystemExit(2)
    bound_state = os.environ.get("FIXTURE_BOUND_EXECUTE_STATE")
    if kind == "execute" and bound_state:
        task_command["provisioning_state"] = bound_state
        task_command["request_digest"] = action["request_digest"]
        state["execute_terminal_probes"] = state.get("execute_terminal_probes", 0) + 1
        save()
        sys.stderr.write(
            "FIXTURE PROVIDER REFUSED: exact worker execution remains bound and "
            "nonterminal: state={}\n".format(bound_state)
        )
        raise SystemExit(2)
    state["calls"].append({
        "type": kind, "slot": action["slot"], "key": key,
        "outcome_expected": bool((action.get("request") or {}).get("outcome_expected")),
        "outcome_dir": action.get("outcome_dir"),
        # Additive: the digest-bound staged manifest the provider actually
        # receives, so a caller can assert what a lane staged.
        "payload_files": (action.get("request") or {}).get("payload_files"),
        "account_files": (action.get("request") or {}).get("account_files"),
        "existing_task_disk": bool((action.get("request") or {}).get("existing_task_disk")),
        "supervisor_sha256": (action.get("request") or {}).get("supervisor_sha256"),
    })
    if kind == "execute" and os.environ.get("FIXTURE_TERMINAL_EXECUTE"):
        task_command["immutable_id"] = "task-command-terminal-{}".format(key[:8])
        task_command["provisioning_state"] = "Failed"
        task_command["request_digest"] = action["request_digest"]
    task_state = str(task_command.get("provisioning_state", "")).lower()
    if (
        kind == "execute"
        and task_state in ("failed", "canceled")
        and task_command.get("request_digest") == action.get("request_digest")
    ):
        result = {
            "idempotency_key": key,
            "action": kind,
            "worker": live_worker,
            "execution": {
                "schema": "fm.worker-execution-terminal/v1",
                "request_digest": action["request_digest"],
                "idempotency_key": key,
                "disposition": "provider-terminal",
                "provisioning_state": task_command["provisioning_state"],
                "task_command_id": (
                    "/fixture/foreign/task-command"
                    if os.environ.get("FIXTURE_FOREIGN_TERMINAL_ID")
                    else task_command["id"]
                ),
            },
        }
        state["seen"][key] = result
    elif key in state["seen"]:
        result = state["seen"][key]
    else:
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
            state["execute_updates"] = state.get("execute_updates", 0) + 1
            request_value = action["request"]
            task_command = state["workers"][slot]["resources"]["task-command"]
            task_command["immutable_id"] = "task-command-execute-{}".format(key[:8])
            task_command["provisioning_state"] = "Succeeded"
            task_command["request_digest"] = action["request_digest"]
            task_command["execution_request_digest"] = action["request_digest"]
            task_command["execution_idempotency_key"] = key
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
                if request_value.get("return_contract"):
                    execution.update({
                        "return_present": True,
                        "return_ref": "refs/fm-return/{}".format(action["request_digest"][:32]),
                        "return_commit": "c" * 40,
                        "return_manifest_sha256": "d" * 64,
                        "outcome_tip": "e" * 40,
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
elif request["operation"] in ("message-put", "message-collect"):
    # The claim-exempt message lane: raw ops, never routed through mutate,
    # never touching the mutate branch's idempotency-key machinery. Blobs
    # live in fixture state as hex under session/... names per slot.
    message = request["action"]
    blobs = state.setdefault("session_blobs", {}).setdefault(str(message["slot"]), {})
    if request["operation"] == "message-put":
        body = Path(message["file"]).read_bytes()
        digest = hashlib.sha256(body).hexdigest()
        if message["lane"] == "json":
            name = "session/in/{}.json".format(digest)
        else:
            name = "session/in/attach/{}.bundle".format(digest)
        replayed = name in blobs
        if not replayed:
            blobs[name] = body.hex()
        state["calls"].append({"type": "message-put", "slot": message["slot"], "name": name})
        save()
        result = {"blob_name": name, "sha256": digest, "bytes": len(body), "replayed": replayed}
    else:
        out = Path(message["output_dir"])
        after = message.get("after")
        fetched = []
        skipped = []
        cursor = after
        for name in sorted(blobs):
            if not name.startswith("session/out/"):
                continue
            local_name = name[len("session/out/"):]
            if after is not None and local_name <= after:
                continue
            body = bytes.fromhex(blobs[name])
            digest = hashlib.sha256(body).hexdigest()
            target = out / local_name
            record = {"blob_name": name, "bytes": len(body), "sha256": digest}
            if target.exists():
                if hashlib.sha256(target.read_bytes()).hexdigest() == digest:
                    skipped.append(record)
                    cursor = local_name
                    continue
                sys.stderr.write(
                    "FIXTURE PROVIDER REFUSED: collected message blob {} diverges "
                    "from the existing local file\n".format(target.name))
                raise SystemExit(1)
            target.write_bytes(body)
            fetched.append(record)
            cursor = local_name
        state["calls"].append({"type": "message-collect", "slot": message["slot"]})
        save()
        result = {"fetched": fetched, "skipped": skipped, "cursor": cursor, "more": False}
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
response["inventory" if request["operation"] == "inventory" else "result"] = result
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
initial_stub_run = subprocess.run(
    [wrapper, "execute", "--task", "task-1", "--task-generation", "gen-1",
     "--assignment-generation", old_assignment, "--wall-seconds", "60",
     "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
     "--", "/usr/bin/true"],
    env=dict(env, FIXTURE_INITIAL_EXECUTE_STUB="1"), text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert initial_stub_run.returncode == 0, initial_stub_run.stderr
execution = json.loads(initial_stub_run.stdout)
assert execution["schema"] == "fm.worker-execution-result/v1" and execution["exit_code"] == 0
assert fixture_state().get("initial_stub_admissions") == 1, fixture_state()
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
refused_existing = armed_execute("--existing-task-disk", "--outcome-dir", str(outcome_dir))
assert refused_existing.returncode != 0 and "requires an authorized return" in refused_existing.stderr, (
    refused_existing.stderr
)
refused_restage = armed_execute(
    "--existing-task-disk", "--payload-dir", str(payload_dir),
    "--account-dir", str(account_dir), "--outcome-dir", str(outcome_dir),
    "--return-kind", "scout",
)
assert refused_restage.returncode != 0 and "cannot replace payload or account" in refused_restage.stderr, (
    refused_restage.stderr
)
recovered = armed_execute(
    "--existing-task-disk", "--outcome-dir", str(outcome_dir), "--return-kind", "scout",
)
assert recovered.returncode == 0, recovered.stderr
recovered_result = json.loads(recovered.stdout)
assert recovered_result["return_present"] is True, recovered_result
recovery_action = [
    entry for entry in fixture_state()["calls"] if entry["type"] == "execute"
][-1]
assert recovery_action["existing_task_disk"] is True, recovery_action
assert recovery_action["supervisor_sha256"] == hashlib.sha256(
    Path(controller_path).with_name("fm-worker-supervisor.py").read_bytes()
).hexdigest(), recovery_action
assert recovery_action["payload_files"] is None, recovery_action
assert recovery_action["account_files"] is None, recovery_action
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
# THE negative safety pin: an ordinary transient provider failure is not the
# structured permanent identity refusal, so abandonment must fail and retain
# both the claim and the absence of any abandonment record.
before_refusals = list(skew_state["cleanup_refusals"])
transient_env = dict(env, FIXTURE_TRANSIENT_EXECUTE_REFUSAL="1")
transient_abandon = subprocess.run(
    [wrapper, "abandon-claim", "--slot", skew_slot,
     "--idempotency-key", skew_claim["idempotency_key"], "--confirm-abandon",
     "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
    env=transient_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert transient_abandon.returncode != 0, transient_abandon
after_transient = controller_state()
assert after_transient["pending_actions"][skew_slot]["idempotency_key"] == skew_claim["idempotency_key"]
assert after_transient["cleanup_refusals"] == before_refusals, after_transient["cleanup_refusals"]
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

# An existing task-command whose live source script is unreadable cannot prove
# that it is safe to submit, and an exact request still Updating is retained as
# an ordinary provider failure. Neither the initial execute nor abandon-claim
# may reach the fixture's Run Command update; removing the injected hostile
# state lets the same durable claim make its one first submission and apply.
before_bound = fixture_state()
bound_updates = before_bound.get("execute_updates", 0)
bound_probes = before_bound.get("execute_terminal_probes", 0)
bound_execute = armed_execute(
    "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
    "--outcome-dir", str(outcome_dir),
    overrides={"FIXTURE_UNREADABLE_EXECUTE_SCRIPT": "1"},
    command="/usr/bin/false",
)
assert bound_execute.returncode != 0 and "source script is unreadable" in bound_execute.stderr, (
    bound_execute.stderr
)
bound_state = controller_state()
bound_slot = str(bound_state["queue"]["task-2@gen-2"]["slot"])
bound_claim = bound_state["pending_actions"][bound_slot]
after_bound_execute = fixture_state()
assert after_bound_execute.get("execute_updates", 0) == bound_updates, after_bound_execute
assert after_bound_execute.get("execute_terminal_probes", 0) == bound_probes + 1, after_bound_execute
bound_abandon = subprocess.run(
    [wrapper, "abandon-claim", "--slot", bound_slot,
     "--idempotency-key", bound_claim["idempotency_key"], "--confirm-abandon",
     "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
    env=dict(env, FIXTURE_BOUND_EXECUTE_STATE="Running"), text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert bound_abandon.returncode != 0 and "remains bound" in bound_abandon.stderr, bound_abandon.stderr
after_bound_abandon = controller_state()
assert after_bound_abandon["pending_actions"][bound_slot]["idempotency_key"] == bound_claim["idempotency_key"]
bound_fixture = fixture_state()
assert bound_fixture.get("execute_updates", 0) == bound_updates, bound_fixture
assert bound_fixture.get("execute_terminal_probes", 0) == bound_probes + 2, bound_fixture
run("abandon-claim", "--slot", bound_slot,
    "--idempotency-key", bound_claim["idempotency_key"], "--confirm-abandon",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
assert bound_slot not in controller_state()["pending_actions"]
assert fixture_state().get("execute_updates", 0) == bound_updates + 1

# Reproduce the Azure wedge: the exact execute claim owns a Run Command whose
# per-execution identity and provisioning state moved to Failed. Reconcile
# records the terminal disposition but retains the claim; abandon replays that
# same terminal result, records before clearing, and ordinary release still
# traverses deallocate -> delete-compute -> reset cleanly.
task3 = controller_state()["queue"]["task-3@gen-3"]
task3_worker = controller_state()["workers"][str(task3["slot"])]
terminal_env = dict(env, FIXTURE_TERMINAL_EXECUTE="1")
terminal_execute = subprocess.run(
    [wrapper, "execute", "--task", "task-3", "--task-generation", "gen-3",
     "--assignment-generation", task3_worker["assignment_generation"],
     "--wall-seconds", "60", "--confirm-execute", "--confirm-subscription",
     env["FM_AZURE_SUBSCRIPTION_ID"], "--", "/usr/bin/true"],
    env=terminal_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert terminal_execute.returncode != 0 and "provider-terminal" in terminal_execute.stderr, terminal_execute.stderr
terminal_state = controller_state()
terminal_slot = str(task3["slot"])
terminal_claim = terminal_state["pending_actions"][terminal_slot]
reconciled = json.loads(run(
    "reconcile", "--apply", "--json", "--confirm-subscription",
    env["FM_AZURE_SUBSCRIPTION_ID"],
).stdout)
assert any(item["type"] == "replay-refused" for item in reconciled["actions"]), reconciled
retained = controller_state()
assert terminal_slot in retained["pending_actions"], retained["pending_actions"]
assert any("provider-terminal" in str(entry.get("note", ""))
           for entry in retained["cleanup_refusals"]), retained["cleanup_refusals"]
# The terminal result must identify the exact task-command path stored in the
# claimed action. A foreign path is an untrusted provider result: ordinary
# apply refuses it, and even explicit abandonment retains the claim.
foreign_terminal_env = dict(
    terminal_env, FIXTURE_FOREIGN_TERMINAL_ID="1"
)
foreign_abandon = subprocess.run(
    [wrapper, "abandon-claim", "--slot", terminal_slot,
     "--idempotency-key", terminal_claim["idempotency_key"],
     "--confirm-abandon", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
    env=foreign_terminal_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert foreign_abandon.returncode != 0 and "task-command identity differs" in foreign_abandon.stderr, (
    foreign_abandon.stderr
)
after_foreign_terminal = controller_state()
assert after_foreign_terminal["pending_actions"][terminal_slot]["idempotency_key"] == (
    terminal_claim["idempotency_key"]
), after_foreign_terminal["pending_actions"]
run("abandon-claim", "--slot", terminal_slot,
    "--idempotency-key", terminal_claim["idempotency_key"],
    "--confirm-abandon", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
cleared = controller_state()
assert terminal_slot not in cleared["pending_actions"], cleared["pending_actions"]
assert any("claim abandoned by operator" in str(entry.get("note", ""))
           and "provider-terminal" in str(entry.get("note", ""))
           for entry in cleared["cleanup_refusals"]), cleared["cleanup_refusals"]
status = json.loads(run("status", "--live", "--json").stdout)
assert status["classification_counts"]["assigned"] == 4, status["classification_counts"]
release(3)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
released_state = controller_state()
released_fixture = fixture_state()
assert terminal_slot not in released_state["workers"], released_state["workers"]
assert terminal_slot not in released_fixture["workers"], released_fixture["workers"]
assert [entry["type"] for entry in released_fixture["calls"]][-3:] == [
    "deallocate", "delete-compute", "reset",
], released_fixture["calls"][-3:]

# The other abandon-only disposition is an exact provider identity refusal.
# A transient/plain ProviderError was retained above; exit 3 plus the explicit
# marker alone permits the operator to record the refusal before clearing.
task4 = controller_state()["queue"]["task-4@gen-4"]
task4_slot = str(task4["slot"])
task4_worker = controller_state()["workers"][task4_slot]
identity_wedge = subprocess.run(
    [wrapper, "execute", "--task", "task-4", "--task-generation", "gen-4",
     "--assignment-generation", task4_worker["assignment_generation"],
     "--wall-seconds", "60", "--payload-dir", str(payload_dir),
     "--account-dir", str(account_dir), "--outcome-dir", str(outcome_dir),
     "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
     "--", "/usr/bin/true"],
    env=dict(env, FIXTURE_OMIT_OUTCOME="1"), text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
)
assert identity_wedge.returncode != 0 and "no outcome disposition" in identity_wedge.stderr
identity_state = controller_state()
identity_claim = identity_state["pending_actions"][task4_slot]
identity_fixture = fixture_state()
identity_fixture["workers"][task4_slot]["resources"]["task-disk"]["immutable_id"] = "foreign-task-disk"
Path(fixture_path).write_text(json.dumps(identity_fixture, sort_keys=True, separators=(",", ":")) + "\n")
run("abandon-claim", "--slot", task4_slot,
    "--idempotency-key", identity_claim["idempotency_key"],
    "--confirm-abandon", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
identity_cleared = controller_state()
assert task4_slot not in identity_cleared["pending_actions"], identity_cleared["pending_actions"]
assert any("claim abandoned by operator: AZURE WORKER PROVIDER REFUSED-IDENTITY:" in
           str(entry.get("note", "")) for entry in identity_cleared["cleanup_refusals"]), (
               identity_cleared["cleanup_refusals"])
# Identity abandonment clears only the impossible claim. It never adopts or
# clears the foreign resource itself; repair the fixture before the ordinary
# release coverage later in this same scenario.
identity_fixture = fixture_state()
identity_fixture["workers"][task4_slot]["resources"]["task-disk"]["immutable_id"] = (
    identity_cleared["workers"][task4_slot]["resources"]["task-disk"]["immutable_id"])
Path(fixture_path).write_text(json.dumps(identity_fixture, sort_keys=True, separators=(",", ":")) + "\n")

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
for number in (2, 4, 5):
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
  local tmp provider fixture home fence receipt retirement out state_file
  fm_test_tmproot_into tmp fm-shared-specialized
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  home="$tmp/home"
  mkdir -p "$home"
  write_fixture_provider "$provider"
  fence=$(printf reservation-fence | shasum -a 256 | awk '{print $1}')
  receipt=$(printf cleanup-proof | shasum -a 256 | awk '{print $1}')
  retirement=$(printf fence-retirement | shasum -a 256 | awk '{print $1}')
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
  # The first retirement may encounter the released controller's v1 document.
  # Migration must preserve every reservation and become rollback-safe at the
  # same save that lands the retirement tombstone.
  python3 - "$state_file" <<'PY'
import json
import sys
from pathlib import Path
path = Path(sys.argv[1])
state = json.loads(path.read_text())
state["schema"] = "fm.worker-lifecycle/v1"
state.pop("retired_capacity_fences", None)
path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
PY
  env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-retire-fence \
      --fence-binding "$fence" \
      --reservation-id azr-123456789abc \
      --retirement-receipt "$retirement" \
      --confirm-subscription "$SUB" >/dev/null
  if env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-retire-fence \
      --fence-binding "$fence" \
      --reservation-id azr-123456789abc \
      --retirement-receipt "$(printf conflicting-retirement | shasum -a 256 | awk '{print $1}')" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "conflicting capacity fence retirement identity was accepted"
  fi
  # The durable retirement is idempotent, but neither reserve entry point may
  # insert or re-admit on that fence after the shared lock opens.
  env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-retire-fence \
      --fence-binding "$fence" \
      --reservation-id azr-123456789abc \
      --retirement-receipt "$retirement" \
      --confirm-subscription "$SUB" >/dev/null
  if env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve \
      --reservation-id azr-retired000001 \
      --fence-binding "$fence" \
      --role validation \
      --sku Standard_D4as_v7 \
      --sku-family StandardDasv7Family \
      --vcpus 4 \
      --amount-usd 25 \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "single reservation entered a retired capacity fence"
  fi
  if env \
    FM_HOME="$home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    "$WRAPPER" capacity-reserve-shape \
      --shape-id shape-retired \
      --fence-binding "$fence" \
      --constituent "reservation-id=azr-retired000002,role=validation,sku=Standard_D4as_v7,sku-family=StandardDasv7Family,vcpus=4,amount-usd=25" \
      --confirm-subscription "$SUB" >/dev/null 2>&1; then
    fail "shape reservation entered a retired capacity fence"
  fi
  python3 - "$state_file" "$fence" "$retirement" <<'PY' \
    || fail "capacity fence retirement was not durable and exact"
import json
import sys
state = json.load(open(sys.argv[1]))
retirement = state["retired_capacity_fences"][sys.argv[2]]
assert state["schema"] == "fm.worker-lifecycle/v2"
assert retirement["reservation_ids"] == ["azr-123456789abc"]
assert retirement["retirement_receipt"] == sys.argv[3]
assert state["capacity_reservations"]["azr-abcdef123456"]["status"] == "reserved"
assert state["capacity_reservations"]["azr-fedcba654321"]["status"] == "queued"
assert "azr-retired000001" not in state["capacity_reservations"]
assert "azr-retired000002" not in state["capacity_reservations"]
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
    # The C3 daily bound is deliberately pinned out of the way: this unit
    # exercises the CUMULATIVE budget lane (its 1499 pressure step must reach
    # capacity_admission's own refusal), and the daily bound over the same
    # reserve entrances has its own dedicated units.
    env \
      FM_HOME="$home" \
      FM_AZURE_SUBSCRIPTION_ID="$SUB" \
      FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_AZURE_WORKER_DAILY_BOUND_USD=100000 \
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
import hashlib
import importlib.util
import json
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
try:
    module.account_evidence(
        {"account_home": [sys.argv[3]], "account_task": ["task-x", "foreign"]},
        "task-x", home,
    )
except module.AuthorityError as exc:
    assert "task identity differs" in str(exc), exc
else:
    raise AssertionError("duplicate account task identity was accepted")

# Azure placement is Pi-only. Its task-level account_home is the vendor-neutral
# multi-profile pool; the controller-selected worker_account_home is keyed by
# the upstream-account binding and contains exactly one projected credential.
# Exercise the live profile labels whose receipts exposed this defect.
pool_home = home / "pi-agent-home"
pool_home.mkdir()
for index, profile in enumerate(
    ("openai-codex", "openai-codex-2", "openai-codex-3", "openai-codex-4"),
    start=1,
):
    credential = {
        "type": "oauth",
        "access": "fixture-access-{}".format(index),
        "refresh": "fixture-refresh-{}".format(index),
        "accountId": "fixture-account-{}".format(index),
        "expires": 4102444800000,
    }
    upstream = hashlib.sha256(credential["accountId"].encode()).hexdigest()[:16]
    binding = module.digest({"provider": "pi", "upstream_account": upstream})
    leased = home / "projected" / binding
    leased.mkdir(parents=True)
    leased.chmod(0o700)
    credential_path = leased / "auth.json"
    credential_path.write_text(json.dumps({"openai-codex": credential}))
    credential_path.chmod(0o600)
    cloud_values = {
        "account_home": [str(pool_home)],
        "account_task": ["task-x"],
        "placement": ["azure"],
        "worker_account_home": [str(leased)],
        "worker_account_profile": [profile],
    }
    worker = {
        "bindings": {"account_binding": binding},
        "account_lease": {
            "account_home": str(leased),
            "account_profile": profile,
        },
    }
    evidence = module.account_evidence(cloud_values, "task-x", home, worker)
    assert profile.encode() in evidence and binding.encode() in evidence, evidence
    foreign = dict(worker)
    foreign["bindings"] = {"account_binding": "f" * 64}
    try:
        module.account_evidence(cloud_values, "task-x", home, foreign)
    except module.AuthorityError as exc:
        assert "binding differs" in str(exc), exc
    else:
        raise AssertionError("foreign Azure account binding was accepted")

    different_profile = dict(cloud_values)
    different_profile["worker_account_profile"] = [profile + "-foreign"]
    try:
        module.account_evidence(different_profile, "task-x", home, worker)
    except module.AuthorityError as exc:
        assert "lease identity differs" in str(exc), exc
    else:
        raise AssertionError("task metadata substituted the Azure account profile")

    alternate = home / "alternate" / binding
    alternate.mkdir(parents=True)
    alternate.chmod(0o700)
    alternate_credential = alternate / "auth.json"
    alternate_credential.write_text(json.dumps({"openai-codex": credential}))
    alternate_credential.chmod(0o600)
    different_home = dict(cloud_values)
    different_home["worker_account_home"] = [str(alternate)]
    try:
        module.account_evidence(different_home, "task-x", home, worker)
    except module.AuthorityError as exc:
        assert "lease identity differs" in str(exc), exc
    else:
        raise AssertionError("task metadata substituted the Azure account home")

    redirected = home / "redirected-{}".format(index)
    redirected.symlink_to(home / "projected", target_is_directory=True)
    redirected_values = dict(cloud_values)
    redirected_values["worker_account_home"] = [str(redirected / binding)]
    redirected_worker = dict(worker)
    redirected_worker["account_lease"] = dict(worker["account_lease"])
    redirected_worker["account_lease"]["account_home"] = str(redirected / binding)
    try:
        module.account_evidence(redirected_values, "task-x", home, redirected_worker)
    except module.AuthorityError as exc:
        assert "path is unsafe" in str(exc), exc
    else:
        raise AssertionError("redirected Azure account lease parent was accepted")

    leased.chmod(0o770)
    try:
        module.account_evidence(cloud_values, "task-x", home, worker)
    except module.AuthorityError as exc:
        assert "owner-private" in str(exc), exc
    else:
        raise AssertionError("group-writable Azure account lease was accepted")
    leased.chmod(0o700)
    credential_path.chmod(0o660)
    try:
        module.account_evidence(cloud_values, "task-x", home, worker)
    except module.AuthorityError as exc:
        assert "owner-private" in str(exc), exc
    else:
        raise AssertionError("group-readable Azure account credential was accepted")
    credential_path.chmod(0o600)
PY
  pass "account authority proves direct homes and all four Azure Pi lease profiles"
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

# The compartment-child shape of this same lane. A compartment child's task
# home is the SECONDMATE's home, while surrender necessarily runs with FM_HOME
# on the primary - the controller document has exactly one home. Resolving the
# primary's state here removed a path that never existed and left the plaintext
# credential in the compartment home with nothing left to remove it.
compartment = Path(env["FM_HOME"]).parent / "compartment"
(compartment / "state").mkdir(parents=True, exist_ok=True)
(compartment / ".fm-secondmate-home").write_text("smc-1\n")
child_staged = compartment / "state" / "task-1.cloud-account"
child_staged.mkdir(parents=True, exist_ok=True)
(child_staged / "auth.json").write_text("{}")
# The controller is what tells the wrapper where a compartment child lives.
# The real admission shape, not a convenient one: parent_task and task_home
# land on the QUEUE ITEM, and only task_home is copied onto the worker record.
# Sourcing the receipt from the worker therefore emitted nothing at all, and
# this case caught exactly that.
_state = controller_state()
_state["queue"]["task-1@gen-1"]["parent_task"] = "smc-1"
_state["queue"]["task-1@gen-1"]["parent_task_generation"] = "gen-s1"
_state["queue"]["task-1@gen-1"]["task_home"] = str(compartment)
_state["workers"][slot]["task_home"] = str(compartment)
(Path(env["FM_HOME"]) / "state/azure-workers/controller.json").write_text(
    json.dumps(_state, sort_keys=True, separators=(",", ":")) + "\n")

# Re-running is idempotent and re-issues the receipt without a second proof.
(Path(env["FM_HOME"]) / "surrender-1.json").unlink()
again = run(*surrender, "--confirm-surrender", *confirm)
assert "already recorded" in again.stdout and "FM-SURRENDERED task-1 gen-1" in again.stdout
assert not (child_staged / "auth.json").exists(), (
    "surrender left a compartment child's staged provider credential in its task home")
assert not child_staged.exists(), (
    "surrender left a compartment child's account staging directory behind")
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
module.ordinary_authority_attempt = lambda _env, _args, _worker, _item: None
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


capacity_reserve_inventory_does_not_hold_controller_lock() {
  python3 - "$CONTROLLER" <<'PY' \
    || fail "capacity-reserve held the controller lock across inventory or skipped durable revalidation"
import contextlib
import copy
import importlib.util
import types
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

reservation_id = "ccm-lock-regression"
fence = "a" * 64
durable = {"retired_capacity_fences": [], "capacity_reservations": {}}
lock = {"held": False, "entries": 0}

@contextlib.contextmanager
def tracked_lock(_env):
    assert not lock["held"]
    lock["held"] = True
    lock["entries"] += 1
    try:
        yield
    finally:
        lock["held"] = False

def load_state(_env):
    return copy.deepcopy(durable)

def save_state(_env, state):
    durable.clear()
    durable.update(copy.deepcopy(state))

def inventory(_env, operation):
    assert operation == "inventory"
    assert not lock["held"], "slow provider inventory ran under the global controller lock"
    assert durable["capacity_reservations"][reservation_id]["status"] == "queued"
    return {"inventory": {"metrics": {"actual_usd": 1.0, "forecast_usd": 2.0}}}

module.controller_lock = tracked_lock
module.load_state = load_state
module.save_state = save_state
module.provider_call = inventory
module.metrics_from_inventory = lambda _inventory: {"actual_usd": 1.0, "forecast_usd": 2.0}
module.daily_bound_refusal = lambda _env, _state, _actual: (None, None)
module.capacity_admission = lambda *_args, **_kwargs: (True, "")
module.budget_limit = lambda _env: 1500.0

args = types.SimpleNamespace(
    reservation_id=reservation_id, fence_binding=fence, role="validation",
    sku="Standard_D4as_v7", sku_family="StandardDasv7Family", vcpus=4,
    amount_usd=25.0, required=False, confirm_subscription="sub",
)
module.command_capacity_reserve({"subscription": "sub"}, args)
assert lock["entries"] == 2, lock
assert durable["capacity_reservations"][reservation_id]["status"] == "reserved"

# A concurrent release during the unlocked inventory window must win. The
# second lock re-reads the durable identity instead of committing from the
# stale pre-inventory document.
durable.clear()
durable.update({"retired_capacity_fences": [], "capacity_reservations": {}})
lock.update(held=False, entries=0)

def inventory_after_release(_env, operation):
    value = inventory(_env, operation)
    durable["capacity_reservations"][reservation_id]["status"] = "released"
    return value

module.provider_call = inventory_after_release
try:
    module.command_capacity_reserve({"subscription": "sub"}, args)
except module.LifecycleError as exc:
    assert "released capacity reservation identity cannot be reused" in str(exc), exc
else:
    raise AssertionError("a concurrently released reservation was re-admitted")
assert lock["entries"] == 2, lock
assert durable["capacity_reservations"][reservation_id]["status"] == "released"
PY
  pass "capacity-reserve inventories outside the controller lock and revalidates durable identity"
}


capacity_release_inventory_does_not_hold_controller_lock() {
  python3 - "$CONTROLLER" <<'PY' \
    || fail "capacity-release held the controller lock across inventory or skipped durable revalidation"
import contextlib
import copy
import importlib.util
import types
import sys

spec = importlib.util.spec_from_file_location("controller", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

reservation_id = "ccm-release-lock-regression"
fence = "a" * 64
receipt = "b" * 64
durable = {
    "capacity_reservations": {
        reservation_id: {
            "reservation_id": reservation_id,
            "fence_binding": fence,
            "status": "queued",
        },
    },
}
lock = {"held": False, "entries": 0}

@contextlib.contextmanager
def tracked_lock(_env):
    assert not lock["held"]
    lock["held"] = True
    lock["entries"] += 1
    try:
        yield
    finally:
        lock["held"] = False

def load_state(_env):
    return copy.deepcopy(durable)

def save_state(_env, state):
    durable.clear()
    durable.update(copy.deepcopy(state))

def inventory(_env, operation):
    assert operation == "inventory"
    assert not lock["held"], "slow provider inventory ran under the global controller lock"
    assert durable["capacity_reservations"][reservation_id]["status"] == "queued"
    return {"inventory": {"capacity_reservations": []}}

module.controller_lock = tracked_lock
module.load_state = load_state
module.save_state = save_state
module.provider_call = inventory
args = types.SimpleNamespace(
    reservation_id=reservation_id, fence_binding=fence,
    cleanup_receipt=receipt, confirm_subscription="sub",
)
module.command_capacity_release({"subscription": "sub"}, args)
assert lock["entries"] == 2, lock
released = durable["capacity_reservations"][reservation_id]
assert released["status"] == "released"
assert released["cleanup_receipt"] == receipt

# An exact concurrent release during the unlocked inventory window is
# idempotent. The second lock re-reads that durable result instead of
# overwriting it from the stale pre-inventory document.
durable["capacity_reservations"][reservation_id] = {
    "reservation_id": reservation_id,
    "fence_binding": fence,
    "status": "queued",
}
lock.update(held=False, entries=0)

def inventory_after_release(_env, operation):
    value = inventory(_env, operation)
    durable["capacity_reservations"][reservation_id].update({
        "status": "released",
        "released_at": "2026-08-26T00:00:00Z",
        "cleanup_receipt": receipt,
    })
    return value

module.provider_call = inventory_after_release
module.command_capacity_release({"subscription": "sub"}, args)
assert lock["entries"] == 2, lock
assert durable["capacity_reservations"][reservation_id]["released_at"] == "2026-08-26T00:00:00Z"
PY
  pass "capacity-release inventories outside the controller lock and revalidates durable identity"
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

# A pending provider action blocks only its own worker slot. An unrelated
# stranded claim must not prevent a dark worker from taking its sanctioned
# surrender path.
state = base_state()
state["pending_actions"] = {"2": {"type": "execute", "request": {"task": "other", "task_generation": "gen-9"}}}
expect_refusal(
    state, args(), "non-assigned or ambiguous",
    attempt=lambda *_a: "WORKER AUTHORITY REFUSED: fixture refusal",
    provider=lambda *_a, **_k: {"inventory": {"workers": []}},
)

state = base_state()
state["pending_actions"] = {"1": {"type": "execute", "request": {"task": "task-1", "task_generation": "gen-1"}}}
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
        real_attempt(env, args(), worker_record(), base_state()["queue"]["task-1@gen-1"])
    except module.LifecycleError as exc:
        assert "failed rather than refusing" in str(exc), exc
    else:
        raise AssertionError("a broken authority tool unlocked surrender")
    module.subprocess.run = lambda *_a, **_k: types.SimpleNamespace(
        returncode=2, stderr=b"WORKER AUTHORITY REFUSED: ordinary task metadata authority is absent", stdout=b"")
    refusal = real_attempt(
        env, args(), worker_record(), base_state()["queue"]["task-1@gen-1"])
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
    (Path(barrier) / "release").touch()
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
(Path(barrier) / "release").unlink()
request(3)
lone = subprocess.Popen(
    [wrapper, "reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]],
    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    assert not wait_for_arrivals(2, 5), "one child produced two arrivals; the detector is broken"
finally:
    (Path(barrier) / "release").touch()
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



secondmate_role_bounds() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-worker-secondmate-bounds
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
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF

  python3 - "$WRAPPER" "$envfile" <<'PY' || fail "a secondmate role or child bound is not enforced"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True, extra=None):
    environment = dict(env)
    environment.update(extra or {})
    result = subprocess.run([wrapper] + list(args), env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

def request(number, *extra_args, check=True, extra=None):
    return run(
        "request", "--task", "task-{}".format(number), "--task-generation", "gen-{}".format(number),
        "--home-binding", binding(1000 + number), "--account-binding", binding(2000 + number),
        "--worktree-binding", binding(3000 + number), "--repository-binding", binding(4000 + number),
        "--repository-generation", "repo-{}".format(number), "--owner-kind", "primary", "--eligible",
        *extra_args, check=check, extra=extra)

def controller_state():
    return json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())

# Depth one: a secondmate compartment is requested only by the primary.
refused = run("request", "--task", "smc-x", "--task-generation", "gen-x",
              "--home-binding", binding(1), "--account-binding", binding(2),
              "--worktree-binding", binding(3), "--repository-binding", binding(4),
              "--repository-generation", "repo-x", "--owner-kind", "secondmate",
              "--role", "secondmate", "--eligible", check=False)
assert refused.returncode != 0 and "requested only by the primary" in refused.stderr, refused.stderr

# parent fields are owned by secondmate-owned author requests only.
refused = request(70, "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=False)
assert refused.returncode != 0 and "secondmate-owned author requests only" in refused.stderr, refused.stderr

# A child cannot name a parent that is not an assigned secondmate compartment.
refused = run("request", "--task", "child-early", "--task-generation", "gen-ce",
              "--home-binding", binding(9), "--account-binding", binding(10),
              "--worktree-binding", binding(11), "--repository-binding", binding(12),
              "--repository-generation", "repo-ce", "--owner-kind", "secondmate", "--eligible",
              "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=False)
assert refused.returncode != 0 and "not an assigned secondmate compartment" in refused.stderr, refused.stderr

# Stand a compartment up for real: request role=secondmate, reconcile to assigned.
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
assert state["queue"]["smc-1@gen-s1"]["status"] == "assigned"
smc_slot = str(state["queue"]["smc-1@gen-s1"]["slot"])
assert state["workers"][smc_slot]["role"] == "secondmate"

# A REAL compartment leg dispatch through command_execute: this is the path
# that refused on the live azaccept run with "payload staging entry is not in
# the reviewed set: fm-secondmate-session.py", because command_execute judged a
# compartment payload against the ordinary crewmate set. The lane now comes
# from the worker's durable role, resolved under the controller lock.
import hashlib
smc_assignment = state["workers"][smc_slot]["assignment_generation"]
staging = Path(env["FM_HOME"]) / "compartment-staging"
payload_dir = staging / "payload"
account_dir = staging / "account"
for directory in (payload_dir, account_dir):
    directory.mkdir(parents=True)
(account_dir / "auth.json").write_text("{}\n")
COMPARTMENT_PAYLOAD = {
    "repo.bundle": b"bundle-fixture",
    "brief.md": b"brief\n",
    "fm-secondmate-session.py": b"# session runner\n",
    "fm-secondmate-spawn.pi-ext.ts": b"// spawn intent\n",
}


def stage_compartment(payload):
    for stale in payload_dir.iterdir():
        stale.unlink()
    for name, body in payload.items():
        (payload_dir / name).write_bytes(body)


def compartment_execute(check=True):
    return run(
        "execute", "--task", "smc-1", "--task-generation", "gen-s1",
        "--assignment-generation", smc_assignment, "--wall-seconds", "60",
        "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
        "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
        "--", "/usr/bin/true", check=check)


# Refusals first: each is raised before any provider claim is minted, so the
# slot is never wedged by one.
for missing in ("fm-secondmate-session.py", "fm-secondmate-spawn.pi-ext.ts"):
    stage_compartment({name: body for name, body in COMPARTMENT_PAYLOAD.items()
                       if name != missing})
    refused = compartment_execute(check=False)
    assert refused.returncode != 0 and "lacks required {}".format(missing) in refused.stderr, (
        refused.stderr)
stage_compartment(dict(COMPARTMENT_PAYLOAD, **{"id_rsa": b"key"}))
refused = compartment_execute(check=False)
assert refused.returncode != 0 and "not in the reviewed set: id_rsa" in refused.stderr, refused.stderr
stage_compartment(dict(COMPARTMENT_PAYLOAD, **{
    "fm-secondmate-spawn.pi-ext.ts": b"x" * (64 * 1024 + 1)}))
refused = compartment_execute(check=False)
assert refused.returncode != 0 and (
    "exceeds its byte bound: fm-secondmate-spawn.pi-ext.ts" in refused.stderr), refused.stderr

# ...and the exact live compartment payload now dispatches, with the
# digest-bound request carrying all four staged entries.
stage_compartment(COMPARTMENT_PAYLOAD)
dispatched = json.loads(compartment_execute().stdout)
assert dispatched["schema"] == "fm.worker-execution-result/v1", dispatched
executed = [entry for entry in
            json.loads(Path(env["FIXTURE_STATE"]).read_text())["calls"]
            if entry["type"] == "execute"][-1]
assert sorted(executed["payload_files"]) == sorted(COMPARTMENT_PAYLOAD), executed
for name, body in COMPARTMENT_PAYLOAD.items():
    assert executed["payload_files"][name] == {
        "sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body)}, executed

# The lane is selected from the worker's DURABLE role, and the two records that
# carry it must agree. create_worker_record copies the item's role onto the
# worker, so a disagreement means durable state has drifted and the controller
# must not guess which side is right. Reached through the real CLI by editing
# ONLY the queue item, leaving the worker record and its cloud-attested VM tags
# intact, which is exactly the drift this fails closed on.
controller_file = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"


def rewrite_item_role(value):
    durable = json.loads(controller_file.read_text())
    item = durable["queue"]["smc-1@gen-s1"]
    if value is None:
        item.pop("role", None)
    else:
        item["role"] = value
    # The worker record keeps role=secondmate; only the queue item moves.
    assert durable["workers"][smc_slot]["role"] == "secondmate", durable["workers"][smc_slot]
    controller_file.write_text(json.dumps(durable, sort_keys=True, separators=(",", ":")))


stage_compartment(COMPARTMENT_PAYLOAD)
for drifted in ("author", None):
    rewrite_item_role(drifted)
    refused = compartment_execute(check=False)
    assert refused.returncode != 0 and "role disagrees with its queue item" in refused.stderr, (
        "a worker/item role disagreement ({}) was not refused: {}".format(
            drifted, refused.stderr))
    # The refusal precedes make_action/slot_lease/claim_pending, so it must not
    # have wedged the slot or left a durable claim behind.
    assert smc_slot not in controller_state()["pending_actions"], controller_state()["pending_actions"]

# Positive control: with the records agreeing again the SAME call succeeds, so
# the refusals above are caused by the disagreement and nothing else.
rewrite_item_role("secondmate")
agreed = compartment_execute()
assert json.loads(agreed.stdout)["schema"] == "fm.worker-execution-result/v1", agreed.stdout

# The compartment cap (default 2): a third compartment refuses.
run("request", "--task", "smc-2", "--task-generation", "gen-s2",
    "--home-binding", binding(31), "--account-binding", binding(32),
    "--worktree-binding", binding(33), "--repository-binding", binding(34),
    "--repository-generation", "repo-s2", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
refused = run("request", "--task", "smc-3", "--task-generation", "gen-s3",
              "--home-binding", binding(41), "--account-binding", binding(42),
              "--worktree-binding", binding(43), "--repository-binding", binding(44),
              "--repository-generation", "repo-s3", "--owner-kind", "primary",
              "--role", "secondmate", "--eligible", check=False)
assert refused.returncode != 0 and "compartment cap reached" in refused.stderr, refused.stderr

def child(number, check=True, extra=None):
    return run(
        "request", "--task", "child-{}".format(number), "--task-generation", "gen-c{}".format(number),
        "--home-binding", binding(5000 + number), "--account-binding", binding(6000 + number),
        "--worktree-binding", binding(7000 + number), "--repository-binding", binding(8000 + number),
        "--repository-generation", "repo-c{}".format(number), "--owner-kind", "secondmate", "--eligible",
        "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=check, extra=extra)

# Fan-out: four children admit, the fifth refuses naming the cap.
for number in (1, 2, 3, 4):
    child(number)
refused = child(5, check=False)
assert refused.returncode != 0 and "active children (cap 4)" in refused.stderr, refused.stderr

# Lifetime total: with the lifetime cap lowered to the four already minted,
# even a freed concurrent slot refuses.
run("withdraw", "--task", "child-1", "--task-generation", "gen-c1", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
refused = child(6, check=False, extra={"FM_SECONDMATE_CHILD_TOTAL": "4"})
assert refused.returncode != 0 and "lifetime child total" in refused.stderr, refused.stderr
# With the default lifetime cap the freed slot admits: the fan-out bound
# counts ACTIVE children, not history.
child(6)

# Release refuses out from under live children, atomically, in command_release.
state = controller_state()
worker = state["workers"][smc_slot]
import hashlib
proof = {
    "schema": "fm.worker-release/v2", "home_binding": worker["bindings"]["home_binding"],
    "task": "smc-1", "task_generation": "gen-s1",
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
        "task": "smc-1", "task_generation": "gen-s1",
        "assignment_generation": worker["assignment_generation"], "verdict": "proved",
        "evidence_digest": binding(offset * 1000 + 77),
    }
    receipt["receipt_digest"] = hashlib.sha256(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    proof["authorities"][authority] = receipt
proof["proof_digest"] = hashlib.sha256(
    json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
proof_path = Path(env["FM_HOME"]) / "smc-proof.json"
proof_path.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
refused = run("release", "--task", "smc-1", "--task-generation", "gen-s1",
              "--proof-file", str(proof_path), check=False)
assert refused.returncode != 0 and "active children name parent" in refused.stderr, refused.stderr
assert "children name parent" in refused.stderr and " 4 " in refused.stderr, (
    "the scan must count THIS generation's children exactly", refused.stderr)

# Quiesce the children; release then succeeds and parent-liveness closes.
for number in (2, 3, 4, 6):
    run("withdraw", "--task", "child-{}".format(number), "--task-generation", "gen-c{}".format(number),
        "--confirm-withdraw", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
# A cross-generation child (hand-planted: no CLI path can mint one, which is
# the point - the scan's generation clause is defense in depth) must not
# block THIS generation's release.
controller_path_state = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"
planted = json.loads(controller_path_state.read_text())
planted["queue"]["ghost@gen-g"] = {
    "schema": "fm.worker-request/v1", "task": "ghost", "task_generation": "gen-g",
    "parent_task": "smc-1", "parent_task_generation": "gen-OLD",
    "owner_kind": "secondmate", "role": "author", "status": "queued",
}
controller_path_state.write_text(json.dumps(planted, sort_keys=True, separators=(",", ":")))
run("release", "--task", "smc-1", "--task-generation", "gen-s1", "--proof-file", str(proof_path))
refused = child(7, check=False)
assert refused.returncode != 0 and "not an assigned secondmate compartment" in refused.stderr, refused.stderr

# A released compartment holds its cap slot while releasing (it still owns
# capacity), and frees it once reconcile resets it to complete: the cap
# counts live compartments, never history.
held = run("request", "--task", "smc-4", "--task-generation", "gen-s4",
           "--home-binding", binding(81), "--account-binding", binding(82),
           "--worktree-binding", binding(83), "--repository-binding", binding(84),
           "--repository-generation", "repo-s4", "--owner-kind", "primary",
           "--role", "secondmate", "--eligible", check=False)
assert held.returncode != 0 and "compartment cap reached" in held.stderr, held.stderr
for _ in range(4):
    run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
    if controller_state()["queue"]["smc-1@gen-s1"]["status"] == "complete":
        break
assert controller_state()["queue"]["smc-1@gen-s1"]["status"] == "complete"
run("request", "--task", "smc-4", "--task-generation", "gen-s4",
    "--home-binding", binding(81), "--account-binding", binding(82),
    "--worktree-binding", binding(83), "--repository-binding", binding(84),
    "--repository-generation", "repo-s4", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")

# The documented local-secondmate lane is preserved: owner_kind=secondmate
# with NO parent pair is an ordinary author request (fm-spawn.sh sends
# exactly this argv from a secondmate home today).
run("request", "--task", "local-sub-child", "--task-generation", "gen-ls",
    "--home-binding", binding(61), "--account-binding", binding(62),
    "--worktree-binding", binding(63), "--repository-binding", binding(64),
    "--repository-generation", "repo-ls", "--owner-kind", "secondmate", "--eligible")
again = run("request", "--task", "local-sub-child", "--task-generation", "gen-ls",
            "--home-binding", binding(61), "--account-binding", binding(62),
            "--worktree-binding", binding(63), "--repository-binding", binding(64),
            "--repository-generation", "repo-ls", "--owner-kind", "secondmate", "--eligible")
assert "already exists with exact identity" in again.stdout, again.stdout

# A lone half of the parent pair refuses for every caller shape.
refused = request(71, "--parent-task-generation", "stray-gen", check=False)
assert refused.returncode != 0 and "travel together" in refused.stderr, refused.stderr

# A child re-request whose parent generation changed refuses as a different
# identity: the parent pair is part of the durable queue identity.
run("request", "--task", "child-8", "--task-generation", "gen-c8",
    "--home-binding", binding(5008), "--account-binding", binding(6008),
    "--worktree-binding", binding(7008), "--repository-binding", binding(8008),
    "--repository-generation", "repo-c8", "--owner-kind", "secondmate", "--eligible",
    "--parent-task", "smc-2", "--parent-task-generation", "gen-s2")
rere = run("request", "--task", "child-8", "--task-generation", "gen-c8",
           "--home-binding", binding(5008), "--account-binding", binding(6008),
           "--worktree-binding", binding(7008), "--repository-binding", binding(8008),
           "--repository-generation", "repo-c8", "--owner-kind", "secondmate", "--eligible",
           "--parent-task", "smc-2", "--parent-task-generation", "gen-OTHER", check=False)
assert rere.returncode != 0 and "different queue identity" in rere.stderr, rere.stderr

# An assigned parent whose worker record is missing (hand-corrupted state -
# no honest path can produce it) refuses loudly instead of silently skipping
# the lifetime bound.
corrupt = json.loads(controller_path_state.read_text())
corrupt["queue"]["smc-broken@gen-b"] = {
    "schema": "fm.worker-request/v1", "task": "smc-broken", "task_generation": "gen-b",
    "owner_kind": "primary", "role": "secondmate", "status": "assigned", "slot": 14,
}
controller_path_state.write_text(json.dumps(corrupt, sort_keys=True, separators=(",", ":")))
refused = run("request", "--task", "child-b", "--task-generation", "gen-cb",
              "--home-binding", binding(5010), "--account-binding", binding(6010),
              "--worktree-binding", binding(7010), "--repository-binding", binding(8010),
              "--repository-generation", "repo-cb", "--owner-kind", "secondmate", "--eligible",
              "--parent-task", "smc-broken", "--parent-task-generation", "gen-b", check=False)
assert refused.returncode != 0 and "no exact worker record" in refused.stderr, refused.stderr
cleaned = json.loads(controller_path_state.read_text())
del cleaned["queue"]["smc-broken@gen-b"]
controller_path_state.write_text(json.dumps(cleaned, sort_keys=True, separators=(",", ":")))

# Author-request golden: no compartment field leaks into an ordinary item.
request(90)
item = controller_state()["queue"]["task-90@gen-90"]
assert item["role"] == "author" and "parent_task" not in item, item
assert sorted(item.keys()) == sorted([
    "schema", "task", "task_generation", "home_binding", "account_binding",
    "worktree_binding", "repository_binding", "repository_generation",
    "owner_kind", "role", "eligible", "discretionary", "status", "enqueued_at",
]), sorted(item.keys())
PY
  pass "secondmate depth, fan-out, lifetime, liveness, compartment cap, and release gates are enforced"
}


compartment_child_task_home() {
  # AMENDMENT 2 section 1: FM_HOME does three separable jobs, and the
  # compartment child is the first case where they differ. --task-home moves
  # jobs 1 and 2 (where the requesting task's local authorities live, and the
  # identity stamped into home_binding) to the SECONDMATE's home while job 3
  # (the identity of the ONE money document) stays on the primary. Every
  # binding here is a REAL mint through authoritative_request_bindings.
  local tmp provider fixture envfile
  # Structural pin: the authorization is decided INSIDE the one exclusive hold
  # that inserts, and before the bounds it anchors. Outside the lock it would
  # be a check against a document another process may have moved on by the
  # time the insert lands, and the queue would admit on stale authority.
  python3 - "$CONTROLLER" <<'PY' || fail "the task home authorization left the controller lock hold"
import ast
import sys
from pathlib import Path

tree = ast.parse(Path(sys.argv[1]).read_text(encoding="utf-8"))
command_request = next(
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "command_request"
)


def calls(scope, name):
    return [
        node for node in ast.walk(scope)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == name
    ]


holds = [
    node for node in ast.walk(command_request)
    if isinstance(node, ast.With) and calls(ast.Module(body=[
        ast.Expr(value=item.context_expr) for item in node.items], type_ignores=[]),
        "controller_lock")
]
assert len(holds) == 1, holds
hold = holds[0]
inside = calls(ast.Module(body=hold.body, type_ignores=[]), "authorize_task_home")
everywhere = calls(command_request, "authorize_task_home")
assert len(inside) == 1, "authorize_task_home is not called inside the controller lock hold"
bounds = calls(ast.Module(body=hold.body, type_ignores=[]), "enforce_child_bounds")
assert len(bounds) == 1, bounds
assert inside[0].lineno < bounds[0].lineno, \
    "the task home is authorized after the bounds it anchors"
# The pre-mint call: nothing may read metadata, resolve caller-named paths, or
# run git under a directory the primary has not authorized yet.
mint = calls(command_request, "authoritative_request_bindings")
assert len(mint) == 1, mint
assert min(call.lineno for call in everywhere) < mint[0].lineno, \
    "the bindings are minted from the task home before it is authorized"
PY
  fm_test_tmproot_into tmp fm-worker-task-home
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  mkdir -p "$tmp/primary/data" "$tmp/primary/state"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$tmp/primary
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF
  python3 - "$WRAPPER" "$envfile" "$tmp" <<'PY' || fail "the authorized task home contract is not enforced"
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, root = sys.argv[1:]
root = Path(root)
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value
primary = Path(env["FM_HOME"])

git_env = dict(env)
git_env.update({
    "GIT_AUTHOR_NAME": "fmtest", "GIT_AUTHOR_EMAIL": "fmtest@example.invalid",
    "GIT_COMMITTER_NAME": "fmtest", "GIT_COMMITTER_EMAIL": "fmtest@example.invalid",
})


def git(*args, cwd):
    subprocess.run(["git"] + list(args), cwd=str(cwd), env=git_env, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def make_repo(path):
    path.mkdir(parents=True, exist_ok=True)
    if (path / ".git").is_dir():
        return path
    git("init", "-q", "-b", "main", ".", cwd=path)
    (path / "README.md").write_text("fixture\n")
    git("add", "README.md", cwd=path)
    git("commit", "-q", "-m", "fixture", "--no-gpg-sign", cwd=path)
    return path


def seed_home(path, marker_id):
    """A seeded secondmate home: marker, AGENTS.md and bin/, as
    validate_secondmate_home requires of one."""
    (path / "state").mkdir(parents=True, exist_ok=True)
    (path / "bin").mkdir(parents=True, exist_ok=True)
    (path / "AGENTS.md").write_text("fixture home\n")
    (path / ".fm-secondmate-home").write_text(marker_id + "\n")
    return path


def pi_pool(root, profiles=8):
    """The fixture Pi credential pool every placed task draws from.

    Shaped exactly as bin/fm-pi-account-home.py requires of a projectable
    profile, with one distinct upstream account per slot, because placement
    leases the ACCOUNT and refuses anything it cannot identify.
    """
    home = root / "pi-pool"
    home.mkdir(parents=True, exist_ok=True)
    pool = {}
    for index in range(1, profiles + 1):
        name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
        pool[name] = {
            "type": "oauth", "access": "fixture-access-{}".format(index),
            "refresh": "fixture-refresh-{}".format(index),
            "accountId": "fixture-account-{}".format(index),
            "expires": 4102444800000,
        }
    (home / "auth.json").write_text(json.dumps(pool, sort_keys=True, indent=2))
    return home


def task_meta(home, task, generation):
    """The ordinary local authorities authoritative_request_bindings reads."""
    worktree = make_repo(root / "worktrees" / task)
    account = pi_pool(root)
    git_dir = worktree / ".git"
    identity = "{}:{}".format(os.stat(git_dir).st_dev, os.stat(git_dir).st_ino)
    (home / "state" / (task + ".meta")).write_text(
        "generation_id={}\nworktree={}\naccount_home={}\naccount_task={}\n"
        "worktree_git_dir_identity={}\n".format(
            generation, worktree, account, task, identity))
    return worktree, account


def registry(*entries):
    lines = ["# secondmates\n"]
    for identifier, home in entries:
        lines.append("- {} - a compartment (home: {}; scope: everything; "
                     "projects: ; added 2026-08-20)\n".format(identifier, home))
    (primary / "data" / "secondmates.md").write_text("".join(lines))


def run(*args, check=True, extra=None):
    environment = dict(env)
    environment.update(extra or {})
    result = subprocess.run([wrapper] + list(args), env=environment, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


def binding(number):
    return format(number, "064x")


def controller_state():
    return json.loads((primary / "state/azure-workers/controller.json").read_text())


def parent_children_total():
    state = controller_state()
    slot = str(state["queue"]["smc-1@gen-s1"]["slot"])
    return int(state["workers"][slot].get("children_total", 0))


# Three secondmate homes: the registered compartment, a registered but never
# assigned one, and an impostor that plants the same marker without a
# registration the primary could only have written itself.
compartment = seed_home(root / "homes" / "compartment", "smc-1")
idle = seed_home(root / "homes" / "idle", "smc-2")
impostor = seed_home(root / "homes" / "impostor", "smc-1")
stranger = seed_home(root / "homes" / "stranger", "smc-9")
registry(("smc-1", compartment), ("smc-2", idle))

# Stand the parent compartment up for real, out of the PRIMARY's document.
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
assert controller_state()["queue"]["smc-1@gen-s1"]["status"] == "assigned"
assert parent_children_total() == 0


def child(task, generation, home, *extra_args, check=True):
    task_meta(home, task, generation)
    return run("request", "--task", task, "--task-generation", generation,
               "--owner-kind", "secondmate", "--eligible",
               "--task-home", str(home), *extra_args, check=check)


# 1. The headline requirement: meta under the --task-home secondmate home,
#    controller under the primary, child ADMITTED with real minted bindings.
worktree, account = task_meta(compartment, "child-1", "gen-c1")
run("request", "--task", "child-1", "--task-generation", "gen-c1",
    "--owner-kind", "secondmate", "--eligible", "--task-home", str(compartment),
    "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
state = controller_state()
item = state["queue"]["child-1@gen-c1"]
assert item["status"] == "queued" and item["owner_kind"] == "secondmate", item
assert item["role"] == "author" and item["parent_task"] == "smc-1", item
# home_binding is the SECONDMATE's home; the money document's own home_binding
# stays the primary's, and verify_state's fence still passes on every command.
assert item["home_binding"] == hashlib.sha256(
    str(compartment.resolve()).encode()).hexdigest(), item["home_binding"]
assert state["home_binding"] == hashlib.sha256(
    str(primary.resolve()).encode()).hexdigest(), state["home_binding"]
assert item["home_binding"] != state["home_binding"]
# The bindings are real mints from the task home's own authorities, and the
# controller selected the least-loaded usable profile from that home's pool.
assert item["account_profile"] == "openai-codex", item
expected_binding = hashlib.sha256(json.dumps(
    {"provider": "pi", "upstream_account": hashlib.sha256(
        b"fixture-account-1").hexdigest()[:16]},
    sort_keys=True, separators=(",", ":")).encode()).hexdigest()
assert item["account_binding"] == expected_binding, item
# Writable projection identity is assignment-private rather than account-keyed.
assert item["account_home"] == str(
    primary / "state" / "azure-workers" / "accounts"
    / item["account_projection_binding"]), item
assert item["account_projection_binding"] != expected_binding, item
snapshot = json.loads((Path(item["account_home"]) / "auth.json").read_text())
assert list(snapshot) == ["openai-codex"], sorted(snapshot)
assert snapshot["openai-codex"]["accountId"] == "fixture-account-1", item
assert account.resolve() == (Path(str(root)) / "pi-pool").resolve(), account
assert item["worktree_binding"] == hashlib.sha256(json.dumps(
    {"git_dir": str((worktree / ".git").resolve()), "worktree": str(worktree.resolve())},
    sort_keys=True, separators=(",", ":")).encode()).hexdigest(), item
head = subprocess.check_output(
    ["git", "-C", str(worktree), "rev-parse", "HEAD"], text=True).strip()
assert item["repository_generation"] == head, item
assert parent_children_total() == 1, "children_total did not increment exactly once"

# 2b. The marker is LOAD BEARING, not decorative: even a home the primary's
#     own registry names for smc-1 refuses while the directory itself is
#     marked for someone else. Drop the marker check and this one admits.
registry(("smc-1", stranger), ("smc-2", idle))
refused = child("child-2b", "gen-c2b", stranger,
                "--parent-task", "smc-1", "--parent-task-generation", "gen-s1",
                check=False)
assert refused.returncode != 0, refused.stdout
assert 'is marked for secondmate "smc-9", not the parent compartment smc-1' in refused.stderr, \
    refused.stderr
assert "child-2b@gen-c2b" not in controller_state()["queue"], refused.stdout
assert parent_children_total() == 1
registry(("smc-1", compartment), ("smc-2", idle))

# 2. A marker naming a DIFFERENT secondmate refuses, mutating nothing.
before = controller_state()
refused = child("child-2", "gen-c2", stranger,
                "--parent-task", "smc-1", "--parent-task-generation", "gen-s1",
                check=False)
assert refused.returncode != 0, refused.stdout
assert 'is marked for secondmate "smc-9", not the parent compartment smc-1' in refused.stderr, \
    refused.stderr
after = controller_state()
assert "child-2@gen-c2" not in after["queue"], "a refused child still mutated the queue"
assert after["queue"] == before["queue"], "a refused child mutated the queue"
assert parent_children_total() == 1, "a refused child still spent the lifetime bound"

# 3a. A home the primary never registered for this secondmate refuses, even
#     though it plants the exact right marker.
refused = child("child-3", "gen-c3", impostor,
                "--parent-task", "smc-1", "--parent-task-generation", "gen-s1",
                check=False)
assert refused.returncode != 0, refused.stdout
assert "is not the home the primary registered for secondmate smc-1" in refused.stderr, \
    refused.stderr
assert parent_children_total() == 1

# 3b. A secondmate absent from the registry entirely refuses, and does so
#     BEFORE the bounds, so the registry is the anchor and not a formality.
refused = child("child-4", "gen-c4", stranger,
                "--parent-task", "smc-9", "--parent-task-generation", "gen-s9",
                check=False)
assert refused.returncode != 0, refused.stdout
assert "does not validly register secondmate smc-9" in refused.stderr, \
    refused.stderr

# 3c. No registry at all: nothing is authorized.
registry_path = primary / "data" / "secondmates.md"
saved = registry_path.read_text()
registry_path.unlink()
refused = child("child-5", "gen-c5", compartment,
                "--parent-task", "smc-1", "--parent-task-generation", "gen-s1",
                check=False)
assert refused.returncode != 0, refused.stdout
assert "does not validly register secondmate smc-1" in refused.stderr, refused.stderr
registry_path.write_text(saved)

# 4. A properly marked AND registered home whose secondmate is not an assigned
#    compartment still hits the UNCHANGED enforce_child_bounds refusal.
refused = child("child-6", "gen-c6", idle,
                "--parent-task", "smc-2", "--parent-task-generation", "gen-s2",
                check=False)
assert refused.returncode != 0, refused.stdout
assert "not an assigned secondmate compartment" in refused.stderr, refused.stderr

# 5. --task-home without a complete parent pair refuses with the exact string.
for extra in ((), ("--parent-task", "smc-1"), ("--parent-task-generation", "gen-s1")):
    refused = child("child-7", "gen-c7", compartment, *extra, check=False)
    assert refused.returncode != 0, refused.stdout
    assert "task home is owned by compartment child requests only" in refused.stderr, \
        (extra, refused.stderr)

# 6. --task-home with --owner-kind primary refuses, and so does --role
#    secondmate: a compartment is never requested through a foreign home.
task_meta(compartment, "child-8", "gen-c8")
refused = run("request", "--task", "child-8", "--task-generation", "gen-c8",
              "--owner-kind", "primary", "--eligible", "--task-home", str(compartment),
              "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=False)
assert refused.returncode != 0, refused.stdout
assert "task home is owned by compartment child requests only" in refused.stderr, refused.stderr
refused = run("request", "--task", "child-8", "--task-generation", "gen-c8",
              "--owner-kind", "secondmate", "--role", "secondmate", "--eligible",
              "--task-home", str(compartment),
              "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=False)
assert refused.returncode != 0, refused.stdout
assert "task home is owned by compartment child requests only" in refused.stderr, refused.stderr

# A symlinked marker is not a marker.
sneak = root / "homes" / "sneak"
(sneak / "state").mkdir(parents=True, exist_ok=True)
os.symlink(str(compartment / ".fm-secondmate-home"), str(sneak / ".fm-secondmate-home"))
registry(("smc-1", sneak), ("smc-2", idle))
refused = child("child-9", "gen-c9", sneak,
                "--parent-task", "smc-1", "--parent-task-generation", "gen-s1",
                check=False)
assert refused.returncode != 0, refused.stdout
assert "carries no ordinary secondmate home marker" in refused.stderr, refused.stderr
PY
  pass "a compartment child is admitted from an authorized task home, and every unauthorized home refuses"
}

local_secondmate_lane_bytes_unchanged() {
  # The AMENDMENT 1 lane that must not move: a LOCAL secondmate home requesting
  # its own cloud crewmate, with no parent pair and no --task-home. The emitted
  # queue item is compared BYTE FOR BYTE against an item this test builds from
  # first principles - every digest recomputed here, independently of the
  # controller - so any drift in the parent-less lane's bytes goes red.
  # Recomputed rather than diffed against main's own binary on purpose: the CI
  # checkout is shallow, so a golden that needed git history would be a
  # conditional skip dressed up as coverage.
  local tmp
  fm_test_tmproot_into tmp fm-worker-local-secondmate-golden
  write_fixture_provider "$tmp/provider.py"
  python3 - "$WRAPPER" "$tmp" "$SUB" <<'PY' || fail "the local-secondmate lane's emitted bytes moved"
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, root, subscription = sys.argv[1:]
root = Path(root)
home = root / "secondmate-home"
(home / "state").mkdir(parents=True, exist_ok=True)
(home / ".fm-secondmate-home").write_text("smc-local\n")

env = os.environ.copy()
env.update({
    "FM_HOME": str(home),
    "FM_AZURE_SUBSCRIPTION_ID": subscription,
    "FM_AZURE_DEPLOYMENT_GENERATION": "dep-one",
    "FM_AZURE_OWNER_TAG": "owner",
    "FM_AZURE_NAMING_PREFIX": "fmtest",
    "FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS": "0",
    "FM_WORKER_PROVIDER_COMMAND": "python3 {}".format(root / "provider.py"),
    "FIXTURE_STATE": str(root / "provider-state.json"),
    "GIT_AUTHOR_NAME": "fmtest", "GIT_AUTHOR_EMAIL": "fmtest@example.invalid",
    "GIT_COMMITTER_NAME": "fmtest", "GIT_COMMITTER_EMAIL": "fmtest@example.invalid",
})

worktree = root / "worktree"
worktree.mkdir(parents=True, exist_ok=True)
subprocess.run(["git", "init", "-q", "-b", "main", "."], cwd=str(worktree), env=env,
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
(worktree / "README.md").write_text("fixture\n")
subprocess.run(["git", "add", "README.md"], cwd=str(worktree), env=env, check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
subprocess.run(["git", "commit", "-q", "-m", "fixture", "--no-gpg-sign"],
               cwd=str(worktree), env=env, check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
account = root / "account"
account.mkdir(parents=True, exist_ok=True)
# The task's provider-account POOL, with more than one profile so the golden
# covers the R5 lane that actually selects and projects; a home with no pool
# refuses, which is why the golden seeds a real one.
(account / "auth.json").write_text(json.dumps({
    "openai-codex": {
        "type": "oauth", "access": "fixture-access-1", "refresh": "fixture-refresh-1",
        "accountId": "fixture-account-1", "expires": 4102444800000,
    },
    "openai-codex-2": {
        "type": "oauth", "access": "fixture-access-2", "refresh": "fixture-refresh-2",
        "accountId": "fixture-account-2", "expires": 4102444800000,
    },
}, sort_keys=True, indent=2))
(account / "auth.json").chmod(0o600)
git_dir = worktree / ".git"
(home / "state" / "local-crew.meta").write_text(
    "generation_id=gen-local\nworktree={}\naccount_home={}\naccount_task=local-crew\n"
    "worktree_git_dir_identity={}:{}\n".format(
        worktree, account, os.stat(git_dir).st_dev, os.stat(git_dir).st_ino))

result = subprocess.run(
    [wrapper, "request", "--task", "local-crew", "--task-generation", "gen-local",
     "--owner-kind", "secondmate", "--eligible"],
    env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert result.returncode == 0, result.stderr
controller = home / "state" / "azure-workers" / "controller.json"
item = json.loads(controller.read_text())["queue"]["local-crew@gen-local"]
assert item.pop("enqueued_at", None), "the queue item lost its enqueue timestamp"
assert item.pop("projected_at", None), "the queue item lost its snapshot timestamp"


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


head = subprocess.check_output(
    ["git", "-C", str(worktree), "rev-parse", "HEAD"], text=True).strip()
home_identity = hashlib.sha256(str(home.resolve()).encode("utf-8")).hexdigest()
pool_home = str(account.resolve())
account_binding = digest({
    "provider": "pi",
    "upstream_account": hashlib.sha256(b"fixture-account-1").hexdigest()[:16],
})
projection_binding = digest({
    "provider": "pi", "home_binding": home_identity, "task": "local-crew",
    "task_generation": "gen-local", "account_pool_home": pool_home,
    "account_profile": "openai-codex", "account_binding": account_binding,
})
expected = {
    "schema": "fm.worker-request/v1",
    "task": "local-crew",
    "task_generation": "gen-local",
    # The parent-less lane still stamps the REQUESTING home, which on this lane
    # IS FM_HOME. --task-home changes where that identity is read from, never
    # what it is here.
    "home_binding": home_identity,
    "account_binding": account_binding,
    "account_profile": "openai-codex",
    "account_projection_binding": projection_binding,
    "account_home": str(
        home / "state" / "azure-workers" / "accounts" / projection_binding),
    "account_pool_home": pool_home,
    "worktree_binding": digest(
        {"worktree": str(worktree.resolve()), "git_dir": str(git_dir.resolve())}),
    "repository_binding": hashlib.sha256(head.encode("ascii")).hexdigest(),
    "repository_generation": head,
    "owner_kind": "secondmate",
    "role": "author",
    "eligible": True,
    "discretionary": True,
    "status": "queued",
}
assert canonical(item) == canonical(expected), (canonical(item), canonical(expected))
assert "parent_task" not in item and "task_home" not in item, item
PY
  pass "the parent-less local-secondmate request records its exact reusable-profile snapshot identity"
}

verify_state_home_fence_golden() {
  # The home fence is what makes ONE document one document. A future edit that
  # drops home_binding from verify_state's tuple, or stops comparing it, must
  # go red HERE rather than silently letting a foreign home load the money
  # document. Structural golden plus the live refusal.
  local tmp
  fm_test_tmproot_into tmp fm-worker-home-fence-golden
  python3 - "$CONTROLLER" <<'PY' || fail "verify_state's exact identity fence moved"
import ast
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text(encoding="utf-8")
tree = ast.parse(source)
target = next(
    node for node in tree.body
    if isinstance(node, ast.FunctionDef) and node.name == "verify_state"
)
loops = [node for node in ast.walk(target) if isinstance(node, ast.For)]
fence = next(
    tuple(element.value for element in loop.iter.elts)
    for loop in loops
    if isinstance(loop.iter, ast.Tuple)
    and all(isinstance(element, ast.Constant) for element in loop.iter.elts)
)
assert fence == (
    "schema", "home_binding", "subscription_binding",
    "deployment_generation", "owner", "prefix",
), fence
PY
  write_fixture_provider "$tmp/provider.py"
  python3 - "$WRAPPER" "$tmp" "$SUB" <<'PY' || fail "a foreign home no longer refuses the money document"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, root, subscription = sys.argv[1:]
root = Path(root)
home = root / "home"
(home / "state").mkdir(parents=True, exist_ok=True)
env = os.environ.copy()
env.update({
    "FM_HOME": str(home),
    "FM_AZURE_SUBSCRIPTION_ID": subscription,
    "FM_AZURE_DEPLOYMENT_GENERATION": "dep-one",
    "FM_AZURE_OWNER_TAG": "owner",
    "FM_AZURE_NAMING_PREFIX": "fmtest",
    "FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS": "0",
    "FM_WORKER_PROVIDER_COMMAND": "python3 {}".format(root / "provider.py"),
    "FIXTURE_STATE": str(root / "provider-state.json"),
    "FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS": "1",
})


def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


run("request", "--task", "task-1", "--task-generation", "gen-1",
    "--home-binding", format(1, "064x"), "--account-binding", format(2, "064x"),
    "--worktree-binding", format(3, "064x"), "--repository-binding", format(4, "064x"),
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible")
controller = home / "state" / "azure-workers" / "controller.json"
document = json.loads(controller.read_text())
assert document["home_binding"] and document["home_binding"] != format(9, "064x")
document["home_binding"] = format(9, "064x")
controller.write_text(json.dumps(document, sort_keys=True, separators=(",", ":")))
refused = run("status", "--json", check=False)
assert refused.returncode != 0, refused.stdout
assert "lifecycle state home_binding binding is not exact" in refused.stderr, refused.stderr
PY
  pass "verify_state still fences the money document on its exact six-field identity"
}

compartment_child_reaches_its_ordinary_exit() {
  # The capability must not admit a child that can never be released. The
  # child's state/<task>.meta lands ONLY under the task home, so the release
  # lane has to look for it there: authority-receipt runs the REAL
  # bin/fm-worker-authority.py against the task home, and the minted receipts
  # verify through the UNMODIFIED release path. Without this an admitted child
  # holds a live worker slot with no ordinary exit, and its architectural
  # "WORKER AUTHORITY REFUSED" would read as a genuine refusal and qualify it
  # for surrender from the moment it was assigned.
  local tmp provider fixture envfile
  fm_test_tmproot_into tmp fm-worker-task-home-release
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  mkdir -p "$tmp/primary/data" "$tmp/primary/state" "$tmp/shim" "$tmp/pi-agent-home"
  write_fixture_provider "$provider"
  # The endpoint oracle must prove the task's pane ABSENT through the real
  # backend helper, so give it a tmux that reports no server.
  cat > "$tmp/shim/tmux" <<'SH'
#!/bin/sh
echo "no server running on /tmp/fm-task-home-release-test" >&2
exit 1
SH
  chmod +x "$tmp/shim/tmux"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$tmp/primary
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1
FM_ACCOUNT_DIRECTORY_ROOT=$tmp/accounts
PATH=$tmp/shim:$PATH
EOF
  python3 - "$WRAPPER" "$envfile" "$tmp" "$ROOT" <<'PY' || fail "an admitted compartment child has no ordinary exit"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, root, repo = sys.argv[1:]
root = Path(root)
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value
primary = Path(env["FM_HOME"])
git_env = dict(env)
git_env.update({
    "GIT_AUTHOR_NAME": "fmtest", "GIT_AUTHOR_EMAIL": "fmtest@example.invalid",
    "GIT_COMMITTER_NAME": "fmtest", "GIT_COMMITTER_EMAIL": "fmtest@example.invalid",
})


def git(*args, cwd, check=True):
    return subprocess.run(["git"] + list(args), cwd=str(cwd), env=git_env, check=check,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


def binding(number):
    return format(number, "064x")


def controller_state():
    return json.loads((primary / "state/azure-workers/controller.json").read_text())


# A seeded secondmate home, registered by the primary.
sub = root / "homes" / "compartment"
(sub / "state").mkdir(parents=True, exist_ok=True)
(sub / "bin").mkdir(parents=True, exist_ok=True)
(sub / "AGENTS.md").write_text("fixture home\n")
(sub / ".fm-secondmate-home").write_text("smc-1\n")
(primary / "data" / "secondmates.md").write_text(
    "# secondmates\n\n- smc-1 - a compartment (home: {}; scope: everything; "
    "projects: ; added 2026-08-20)\n".format(sub))

# An ORIGIN the child's landing evidence can prove reachability against, and a
# task worktree cloned from it with its work already pushed.
origin = root / "origin.git"
seed = root / "seed"
seed.mkdir(parents=True, exist_ok=True)
git("init", "-q", "-b", "main", ".", cwd=seed)
(seed / "README.md").write_text("fixture\n")
git("add", "README.md", cwd=seed)
git("commit", "-q", "-m", "fixture", "--no-gpg-sign", cwd=seed)
subprocess.run(["git", "clone", "-q", "--bare", str(seed), str(origin)], check=True,
               env=git_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
worktree = root / "child-worktree"
subprocess.run(["git", "clone", "-q", str(origin), str(worktree)], check=True,
               env=git_env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
# The account directory the real account helper validates, and the completion
# report the report authority requires - both in the SECONDMATE's home.
account = root / "pi-agent-home"
# The same directory is this task's provider-account POOL, exactly as the real
# cloud lane's account_home (the Pi coding-agent home) is: placement leases one
# profile out of it and refuses a home it cannot identify an account in.
(account / "auth.json").write_text(json.dumps({
    "openai-codex": {
        "type": "oauth", "access": "fixture-access-1", "refresh": "fixture-refresh-1",
        "accountId": "fixture-account-1", "expires": 4102444800000,
    },
}, sort_keys=True, indent=2))
(sub / "data" / "child-1").mkdir(parents=True, exist_ok=True)
(sub / "data" / "child-1" / "completion.md").write_text(
    "# child-1\n\n## Summary\ns\n\n## What changed\nc\n\n## Verification\nv\n\n"
    "## Visual evidence\ne\n\n## Artifacts\na\n\n## Follow-ups\nf\n")
git_dir = worktree / ".git"
head = git("rev-parse", "HEAD", cwd=worktree).stdout.strip()
(sub / "state" / "child-1.meta").write_text(
    "generation_id=gen-c1\nworktree={}\naccount_home={}\naccount_task=child-1\n"
    "kind=ship\nwindow=fmtest:1\nbackend=tmux\n"
    "worktree_git_dir_identity={}:{}\n".format(
        worktree, account, os.stat(git_dir).st_dev, os.stat(git_dir).st_ino))

# Parent compartment, assigned.
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])

# The child, admitted from its authorized task home with real minted bindings.
run("request", "--task", "child-1", "--task-generation", "gen-c1",
    "--owner-kind", "secondmate", "--eligible", "--task-home", str(sub),
    "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
item = state["queue"]["child-1@gen-c1"]
assert item["status"] == "assigned", item
# The PATH is durable, on the queue item AND on the worker record: the release
# lane sees only the worker.
assert item["task_home"] == str(sub), item
worker = state["workers"][str(item["slot"])]
assert worker["task_home"] == str(sub), worker
assignment = worker["assignment_generation"]
# The real cloud spawn appends the controller-selected lease only after the
# request succeeds. Its path has no claude/codex vendor component, so the
# public authority-receipt command must use this exact placement record rather
# than guess a direct-account vendor from account_home.
with (sub / "state" / "child-1.meta").open("a") as stream:
    stream.write(
        "placement=azure\nworker_account_home={}\nworker_account_profile={}\n".format(
            item["account_home"], item["account_profile"]
        )
    )

receipt_path = root / "child-receipts.json"
metadata_path = sub / "state" / "child-1.meta"
metadata_text = metadata_path.read_text()
metadata_variants = {
    "missing placement": metadata_text.replace("placement=azure\n", ""),
    "duplicate placement": metadata_text + "placement=azure\n",
    "conflicting placement": metadata_text.replace("placement=azure\n", "placement=local\n"),
    "missing kind": metadata_text.replace("kind=ship\n", ""),
    "duplicate kind": metadata_text + "kind=ship\n",
    "malformed kind": metadata_text.replace("kind=ship\n", "kind=unknown\n"),
}
for label, variant in metadata_variants.items():
    metadata_path.write_text(variant)
    refused_metadata = run(
        "authority-receipt", "--task", "child-1", "--task-generation", "gen-c1",
        "--assignment-generation", assignment, "--output", str(receipt_path), check=False)
    assert refused_metadata.returncode != 0, "{} metadata selected release authority".format(label)
    assert not receipt_path.exists(), "{} metadata wrote release receipts".format(label)
metadata_path.write_text(metadata_text)
missing_return = run(
    "authority-receipt", "--task", "child-1", "--task-generation", "gen-c1",
    "--assignment-generation", assignment, "--output", str(receipt_path), check=False)
assert missing_return.returncode != 0, "Azure authority fell back to forge landing without a return"
assert "cloud return result custody is absent" in missing_return.stderr, missing_return.stderr
assert not receipt_path.exists(), "missing cloud return wrote release receipts"

import hashlib
bundle = b"fixture cloud return bundle\n"
outcome_dir = sub / "state" / "child-1.cloud-outcome"
outcome_dir.mkdir()
(outcome_dir / "outcome.bundle").write_bytes(bundle)
manifest = {
    "schema": "fm.worker-return/v1",
    "task": "child-1",
    "task_generation": "gen-c1",
    "assignment_generation": assignment,
    "request_digest": "5" * 64,
    "repository_generation": head,
    "kind": "ship",
    "report_required": True,
    "report_path": "data/child-1/completion.md",
    "status_path": "state/child-1.status",
    "visuals_path": "data/child-1/visuals",
    "branch": "fm/child-1",
    "outcome_commits": 0,
    "outcome_tip": head,
    "uncommitted_changes": False,
    "artifacts": {},
}
manifest_bytes = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
(sub / "data" / "child-1" / "cloud-return.json").write_bytes(manifest_bytes)
(sub / "state" / "child-1.status").write_text("done: cloud outcome returned to local custody\n")
result = {
    "schema": "fm.worker-execution-result/v1",
    "task": "child-1",
    "task_generation": "gen-c1",
    "assignment_generation": assignment,
    "repository_generation": head,
    "return_present": True,
    "request_digest": "5" * 64,
    "outcome_bytes": len(bundle),
    "outcome_sha256": hashlib.sha256(bundle).hexdigest(),
    "return_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
    "outcome_commits": 0,
    "outcome_tip": head,
    "outcome_uncommitted_changes": False,
}
result["result_digest"] = hashlib.sha256(json.dumps(
    result, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
(sub / "state" / "child-1.worker-result.json").write_text(json.dumps(
    result, sort_keys=True, separators=(",", ":")) + "\n")

# The ordinary exit, for real: authority-receipt runs the unmodified authority
# tool, and it must find the child's metadata under the TASK home.
receipts = run("authority-receipt", "--task", "child-1", "--task-generation", "gen-c1",
               "--assignment-generation", assignment, "--output", str(receipt_path))
assert "receipts written" in receipts.stdout, receipts.stdout
minted = json.loads(receipt_path.read_text())
assert set(minted["authorities"]) == {"endpoint", "report", "landing", "account", "worktree"}, minted
assert all(entry["verdict"] == "proved" for entry in minted["authorities"].values()), minted
assert minted["repository_generation"] == head, minted

# And the proof verifies through the UNCHANGED release path.
proof = json.loads(run(
    "proof-template", "--task", "child-1", "--task-generation", "gen-c1").stdout)
proof["authorities"] = minted["authorities"]
unsigned = dict(proof)
unsigned.pop("proof_digest", None)
proof["proof_digest"] = hashlib.sha256(json.dumps(
    unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
proof_path = root / "child-proof.json"
proof_path.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
run("release", "--task", "child-1", "--task-generation", "gen-c1",
    "--proof-file", str(proof_path))
final = controller_state()
assert final["queue"]["child-1@gen-c1"]["status"] in ("releasing", "complete"), \
    final["queue"]["child-1@gen-c1"]

# A tampered durable task home cannot redirect the authority lane: the recorded
# home_binding is the fence. The decoy is a home that would otherwise mint the
# receipts successfully, so dropping the fence ADMITS a foreign home rather
# than merely changing which error appears.
decoy = root / "homes" / "decoy"
(decoy / "state").mkdir(parents=True, exist_ok=True)
(decoy / "bin").mkdir(parents=True, exist_ok=True)
(decoy / "AGENTS.md").write_text("fixture home\n")
(decoy / ".fm-secondmate-home").write_text("smc-1\n")
(decoy / "data" / "child-1").mkdir(parents=True, exist_ok=True)
(decoy / "data" / "child-1" / "completion.md").write_text(
    (sub / "data" / "child-1" / "completion.md").read_text())
(decoy / "state" / "child-1.meta").write_text((sub / "state" / "child-1.meta").read_text())
tampered = json.loads((primary / "state/azure-workers/controller.json").read_text())
victim = tampered["workers"].get(str(item["slot"]))
assert victim is not None, "the released worker record vanished before the fence check"
victim["task_home"] = str(decoy)
(primary / "state/azure-workers/controller.json").write_text(
    json.dumps(tampered, sort_keys=True, separators=(",", ":")))
refused = run("authority-receipt", "--task", "child-1", "--task-generation", "gen-c1",
              "--assignment-generation", assignment, "--output", str(receipt_path),
              check=False)
assert refused.returncode != 0, "a foreign task home minted receipts: {}".format(refused.stdout)
assert "does not match its recorded home binding" in refused.stderr, refused.stderr

# Restore the exact released document, converge provider reset, and prove the
# host cleanup removes only this completed assignment's projection.
projection_home = Path(item["account_home"])
assert projection_home.is_dir(), projection_home
(primary / "state/azure-workers/controller.json").write_text(
    json.dumps(final, sort_keys=True, separators=(",", ":")))
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
completed = controller_state()
assert completed["queue"]["child-1@gen-c1"]["status"] == "complete", completed
assert not projection_home.exists(), "provider reset left the assignment projection behind"
PY
  pass "an admitted child releases through ordinary proofs and reset removes its exact profile projection"
}

task_home_registry_is_read_by_the_canonical_reader() {
  # The money path must be the STRICTEST reader of data/secondmates.md, never
  # the most permissive. Every shape below is one the repo's own
  # fm_secondmate_registry_query refuses; each must refuse here too, and the
  # test proves the canonical reader really rejects each shape rather than
  # asserting it from memory.
  local tmp provider fixture envfile
  fm_test_tmproot_into tmp fm-worker-task-home-registry
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  mkdir -p "$tmp/primary/data" "$tmp/primary/state"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$tmp/primary
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF
  python3 - "$WRAPPER" "$envfile" "$tmp" "$ROOT" <<'PY' || fail "the registry is not read through the canonical reader"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, root, repo = sys.argv[1:]
root = Path(root)
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value
primary = Path(env["FM_HOME"])
registry_path = primary / "data" / "secondmates.md"
git_env = dict(env)
git_env.update({
    "GIT_AUTHOR_NAME": "fmtest", "GIT_AUTHOR_EMAIL": "fmtest@example.invalid",
    "GIT_COMMITTER_NAME": "fmtest", "GIT_COMMITTER_EMAIL": "fmtest@example.invalid",
})


def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


def canonical_reader_accepts(secondmate):
    """What bin/fm-account-routing-lib.sh itself says about this registry."""
    script = ('. "$1" || exit 1\n'
              'fm_secondmate_registry_query "$2" query "$3" home\n')
    result = subprocess.run(
        ["bash", "-c", script, "probe",
         str(Path(repo) / "bin" / "fm-account-routing-lib.sh"),
         str(registry_path), secondmate],
        env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return result.returncode == 0


def seed_home(path, marker_id):
    (path / "state").mkdir(parents=True, exist_ok=True)
    (path / "bin").mkdir(parents=True, exist_ok=True)
    (path / "AGENTS.md").write_text("fixture home\n")
    (path / ".fm-secondmate-home").write_text(marker_id + "\n")
    return path


def make_repo(path):
    path.mkdir(parents=True, exist_ok=True)
    if (path / ".git").is_dir():
        return path
    for argv in (["git", "init", "-q", "-b", "main", "."], ["git", "add", "README.md"],
                 ["git", "commit", "-q", "-m", "fixture", "--no-gpg-sign"]):
        if argv[1] == "add":
            (path / "README.md").write_text("fixture\n")
        subprocess.run(argv, cwd=str(path), env=git_env, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    return path


def pi_pool(root, profiles=8):
    """The fixture Pi credential pool every placed task draws from.

    Shaped exactly as bin/fm-pi-account-home.py requires of a projectable
    profile, with one distinct upstream account per slot, because placement
    leases the ACCOUNT and refuses anything it cannot identify.
    """
    home = root / "pi-pool"
    home.mkdir(parents=True, exist_ok=True)
    pool = {}
    for index in range(1, profiles + 1):
        name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
        pool[name] = {
            "type": "oauth", "access": "fixture-access-{}".format(index),
            "refresh": "fixture-refresh-{}".format(index),
            "accountId": "fixture-account-{}".format(index),
            "expires": 4102444800000,
        }
    (home / "auth.json").write_text(json.dumps(pool, sort_keys=True, indent=2))
    return home


def task_meta(home, task, generation):
    worktree = make_repo(root / "worktrees" / task)
    account = pi_pool(root)
    git_dir = worktree / ".git"
    (home / "state" / (task + ".meta")).write_text(
        "generation_id={}\nworktree={}\naccount_home={}\naccount_task={}\n"
        "worktree_git_dir_identity={}:{}\n".format(
            generation, worktree, account, task,
            os.stat(git_dir).st_dev, os.stat(git_dir).st_ino))


def binding(number):
    return format(number, "064x")


sub = seed_home(root / "homes" / "compartment", "smc-1")
other = seed_home(root / "homes" / "other", "smc-2")
link_parent = root / "linked"
link_parent.mkdir(parents=True, exist_ok=True)
os.symlink(str(root / "homes"), str(link_parent / "homes"))

good = "- smc-1 - a compartment (home: {}; scope: everything; projects: ; added 2026-08-20)\n".format(sub)


def write_registry(*lines):
    registry_path.write_text("# secondmates\n\n" + "".join(lines))


# Stand the parent compartment up once, against a VALID registry.
write_registry(good)
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])


def child(number, home, check=False, cwd=None):
    task = "reg-child-{}".format(number)
    task_meta(sub, task, "gen-r{}".format(number))
    task_meta(other, task, "gen-r{}".format(number))
    args = ["request", "--task", task, "--task-generation", "gen-r{}".format(number),
            "--owner-kind", "secondmate", "--eligible", "--task-home", str(home),
            "--parent-task", "smc-1", "--parent-task-generation", "gen-s1"]
    result = subprocess.run([wrapper] + args, env=env, text=True, cwd=cwd,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


shapes = [
    ("relative home",
     ["- smc-1 - a compartment (home: homes/compartment; scope: everything; projects: ; added 2026-08-20)\n"]),
    ("path through a symlinked component",
     ["- smc-1 - a compartment (home: {}/homes/compartment; scope: everything; projects: ; added 2026-08-20)\n".format(link_parent)]),
    ("dot-dot component",
     ["- smc-1 - a compartment (home: {}/homes/../homes/compartment; scope: everything; projects: ; added 2026-08-20)\n".format(root)]),
    ("one corrupt trailing line", [good, "- smc-9 - truncated entry (home: /nowhere\n"]),
    ("trailing spaces", [good.rstrip("\n") + "   \n"]),
    ("one home under two ids",
     [good, "- smc-dup - the same home (home: {}; scope: everything; projects: ; added 2026-08-20)\n".format(sub)]),
]
# Every shape is exercised even after one fails, so a weakened reader reports
# ALL the shapes it admits rather than stopping at the first.
admitted = []
misrefused = []
for number, (label, lines) in enumerate(shapes, start=1):
    write_registry(*lines)
    assert not canonical_reader_accepts("smc-1"), \
        "the canonical reader ACCEPTS the {} shape, so this case proves nothing".format(label)
    # The relative shape runs from the directory it would resolve against, so a
    # cwd-anchored reader really does admit here instead of missing by luck.
    result = child(number, sub, cwd=str(root) if label == "relative home" else None)
    if result.returncode == 0:
        admitted.append(label)
    elif "does not validly register secondmate smc-1" not in result.stderr:
        misrefused.append((label, result.stderr.strip()[-200:]))
assert not admitted, "shapes the canonical reader refuses were ADMITTED: {}".format(admitted)
assert not misrefused, misrefused

# A valid registry that simply does not name this secondmate refuses the same way.
write_registry("- smc-2 - another compartment (home: {}; scope: everything; projects: ; added 2026-08-20)\n".format(other))
assert canonical_reader_accepts("smc-2")
refused = child(90, sub)
assert refused.returncode != 0, refused.stdout
assert "does not validly register secondmate smc-1" in refused.stderr, refused.stderr

# And the valid registry still ADMITS, so the matrix above is refusing for the
# shape and not because the lane is simply broken.
write_registry(good)
admitted = child(99, sub, check=True)
assert admitted.returncode == 0, admitted.stderr
PY
  pass "the money path refuses every registry shape the repo's own canonical reader refuses"
}

task_home_marker_matches_the_home_rules() {
  # The marker link must be as strong as validate_secondmate_home, not merely
  # marker-shaped: the primary's own home is never a task home, and the marker
  # comparison strips trailing newlines the way the shell readers' $(cat) does,
  # never leading whitespace.
  local tmp provider fixture envfile
  fm_test_tmproot_into tmp fm-worker-task-home-marker
  provider="$tmp/provider.py"
  fixture="$tmp/provider-state.json"
  mkdir -p "$tmp/primary/data" "$tmp/primary/state" "$tmp/primary/bin"
  printf 'fixture home\n' > "$tmp/primary/AGENTS.md"
  write_fixture_provider "$provider"
  envfile="$tmp/env"
  cat >"$envfile" <<EOF
FM_HOME=$tmp/primary
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_AZURE_NAMING_PREFIX=fmtest
FM_WORKER_PROVIDER_COMMAND=python3 $provider
FIXTURE_STATE=$fixture
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF
  python3 - "$WRAPPER" "$envfile" "$tmp" <<'PY' || fail "the task home marker rules are weaker than validate_secondmate_home"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, root = sys.argv[1:]
root = Path(root)
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value
primary = Path(env["FM_HOME"])


def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result


def binding(number):
    return format(number, "064x")


def seed_home(path, marker_bytes):
    (path / "state").mkdir(parents=True, exist_ok=True)
    (path / "bin").mkdir(parents=True, exist_ok=True)
    (path / "AGENTS.md").write_text("fixture home\n")
    (path / ".fm-secondmate-home").write_text(marker_bytes)
    return path


git_env = dict(env)
git_env.update({
    "GIT_AUTHOR_NAME": "fmtest", "GIT_AUTHOR_EMAIL": "fmtest@example.invalid",
    "GIT_COMMITTER_NAME": "fmtest", "GIT_COMMITTER_EMAIL": "fmtest@example.invalid",
})


def pi_pool(root, profiles=8):
    """The fixture Pi credential pool every placed task draws from.

    Shaped exactly as bin/fm-pi-account-home.py requires of a projectable
    profile, with one distinct upstream account per slot, because placement
    leases the ACCOUNT and refuses anything it cannot identify.
    """
    home = root / "pi-pool"
    home.mkdir(parents=True, exist_ok=True)
    pool = {}
    for index in range(1, profiles + 1):
        name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
        pool[name] = {
            "type": "oauth", "access": "fixture-access-{}".format(index),
            "refresh": "fixture-refresh-{}".format(index),
            "accountId": "fixture-account-{}".format(index),
            "expires": 4102444800000,
        }
    (home / "auth.json").write_text(json.dumps(pool, sort_keys=True, indent=2))
    return home


def task_meta(home, task, generation):
    """A COMPLETE set of local authorities, so that when a home rule is deleted
    the request is genuinely ADMITTED rather than failing later on a missing
    metadata file. Every refusal below has to be the rule, not an accident."""
    worktree = root / "worktrees" / task
    worktree.mkdir(parents=True, exist_ok=True)
    if not (worktree / ".git").is_dir():
        for argv in (["git", "init", "-q", "-b", "main", "."], ["git", "add", "README.md"],
                     ["git", "commit", "-q", "-m", "fixture", "--no-gpg-sign"]):
            if argv[1] == "add":
                (worktree / "README.md").write_text("fixture\n")
            subprocess.run(argv, cwd=str(worktree), env=git_env, check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    account = pi_pool(root)
    git_dir = worktree / ".git"
    (home / "state").mkdir(parents=True, exist_ok=True)
    (home / "state" / (task + ".meta")).write_text(
        "generation_id={}\nworktree={}\naccount_home={}\naccount_task={}\n"
        "worktree_git_dir_identity={}:{}\n".format(
            generation, worktree, account, task,
            os.stat(git_dir).st_dev, os.stat(git_dir).st_ino))


sub = seed_home(root / "homes" / "compartment", "smc-1\n")
nested = seed_home(primary / "inner-home", "smc-1\n")
padded = seed_home(root / "homes" / "padded", "  smc-1\n")
(primary / ".fm-secondmate-home").write_text("smc-1\n")


def registry(*entries):
    (primary / "data" / "secondmates.md").write_text(
        "# secondmates\n\n" + "".join(
            "- {} - a compartment (home: {}; scope: everything; projects: ; "
            "added 2026-08-20)\n".format(identifier, home)
            for identifier, home in entries))


registry(("smc-1", sub))
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])


def child(number, home):
    task_meta(home, "mark-{}".format(number), "gen-m{}".format(number))
    return run("request", "--task", "mark-{}".format(number),
               "--task-generation", "gen-m{}".format(number),
               "--owner-kind", "secondmate", "--eligible", "--task-home", str(home),
               "--parent-task", "smc-1", "--parent-task-generation", "gen-s1", check=False)


# The primary's OWN home, marked and registered, is still never a task home.
registry(("smc-1", primary))
refused = child(1, primary)
assert refused.returncode != 0, refused.stdout
assert "cannot be, contain, or sit inside the active firstmate home" in refused.stderr, refused.stderr

# Nor is a home nested inside it.
registry(("smc-1", nested))
refused = child(2, nested)
assert refused.returncode != 0, refused.stdout
assert "cannot be, contain, or sit inside the active firstmate home" in refused.stderr, refused.stderr

# Leading whitespace in the marker is not the secondmate id.
registry(("smc-1", padded))
refused = child(3, padded)
assert refused.returncode != 0, refused.stdout
assert 'is marked for secondmate "  smc-1", not the parent compartment smc-1' in refused.stderr, \
    refused.stderr

# A relative --task-home never resolves against the caller's cwd.
registry(("smc-1", sub))
task_meta(sub, "mark-4", "gen-m4")
relative = subprocess.run(
    [wrapper, "request", "--task", "mark-4", "--task-generation", "gen-m4",
     "--owner-kind", "secondmate", "--eligible", "--task-home", "homes/compartment",
     "--parent-task", "smc-1", "--parent-task-generation", "gen-s1"],
    env=env, cwd=str(root), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert relative.returncode != 0, relative.stdout
assert "--task-home must be an absolute path" in relative.stderr, relative.stderr

# A marker carrying control bytes never reaches operator output raw.
sneaky = seed_home(root / "homes" / "sneaky", "smc-\x07\x1b[31mX\n")
registry(("smc-1", sneaky))
refused = child(5, sneaky)
assert refused.returncode != 0, refused.stdout
assert "\x1b" not in refused.stderr and "\x07" not in refused.stderr, repr(refused.stderr)
assert "is marked for secondmate" in refused.stderr, refused.stderr
PY
  pass "the task home marker link enforces the same home rules and never echoes raw marker bytes"
}

compartment_fixture_env() {  # <tmproot-label> -> sets COMPARTMENT_ENVFILE/COMPARTMENT_FIXTURE
  # Shared stand-up for the PR-6 compartment units: fixture provider, envfile.
  local tmp
  fm_test_tmproot_into tmp "$1"
  COMPARTMENT_FIXTURE="$tmp/provider-state.json"
  mkdir -p "$tmp/home"
  write_fixture_provider "$tmp/provider.py"
  COMPARTMENT_ENVFILE="$tmp/env"
  cat >"$COMPARTMENT_ENVFILE" <<EOF
FM_HOME=$tmp/home
FM_AZURE_SUBSCRIPTION_ID=$SUB
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=fmtest
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
FM_WORKER_PROVIDER_COMMAND=python3 $tmp/provider.py
FIXTURE_STATE=$COMPARTMENT_FIXTURE
FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1
EOF
}

surrender_orphan_confirm() {
  # AMENDMENT 1 closed: surrendering a parent with live children refuses
  # unless --confirm-orphan-children, and the flag path stamps a durable
  # reparented_to note on every live child in the same lock hold.
  compartment_fixture_env fm-worker-surrender-orphan
  python3 - "$WRAPPER" "$COMPARTMENT_ENVFILE" "$COMPARTMENT_FIXTURE" <<'PY' || fail "the surrender orphan-confirm contract is not enforced"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, fixture_path = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

state_path = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"

def controller_state():
    return json.loads(state_path.read_text())

# Compartment plus one ASSIGNED child; a second child stays QUEUED, so the
# stamp path must cover both live shapes.
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
run("request", "--task", "child-1", "--task-generation", "gen-c1",
    "--home-binding", binding(31), "--account-binding", binding(32),
    "--worktree-binding", binding(33), "--repository-binding", binding(34),
    "--repository-generation", "repo-c1", "--owner-kind", "secondmate", "--eligible",
    "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
run("request", "--task", "child-2", "--task-generation", "gen-c2",
    "--home-binding", binding(41), "--account-binding", binding(42),
    "--worktree-binding", binding(43), "--repository-binding", binding(44),
    "--repository-generation", "repo-c2", "--owner-kind", "secondmate", "--eligible",
    "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
state = controller_state()
assert state["queue"]["smc-1@gen-s1"]["status"] == "assigned"
assert state["queue"]["child-1@gen-c1"]["status"] == "assigned"
assert state["queue"]["child-2@gen-c2"]["status"] == "queued"
slot = str(state["queue"]["smc-1@gen-s1"]["slot"])

# A hand-planted COMPLETE child (release+reset is the only honest path and is
# exercised elsewhere): it must be untouched by the orphan stamping.
state["queue"]["child-done@gen-cd"] = {
    "schema": "fm.worker-request/v1", "task": "child-done", "task_generation": "gen-cd",
    "parent_task": "smc-1", "parent_task_generation": "gen-s1",
    "owner_kind": "secondmate", "role": "author", "status": "complete",
}
state_path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")

# Dark the parent compute (the TTL fires outside the controller).
fixture = json.loads(Path(fixture_path).read_text())
fixture["workers"][slot]["resources"]["vm"]["power_state"] = "VM deallocated"
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")) + "\n")

surrender = [
    "surrender", "--task", "smc-1", "--task-generation", "gen-s1",
    "--reason", "compartment authority evidence is unrecoverable",
    "--output", str(Path(env["FM_HOME"]) / "surrender-smc.json"),
    "--confirm-surrender", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
]

# Without the orphan confirmation: the exact refusal, and nothing persisted.
refused = run(*surrender, check=False)
expected = ("surrender refuses: 2 active children name parent smc-1; pass "
            "--confirm-orphan-children to reparent them to the primary deliberately")
assert refused.returncode != 0 and expected in refused.stderr, refused.stderr
state = controller_state()
assert state["workers"][slot].get("release_proof") is None
assert all("reparented_to" not in entry for entry in state["queue"].values())

# With the flag: surrender proceeds, both live children carry the durable
# note, the complete child is untouched, and the block records the count.
result = run(*surrender, "--confirm-orphan-children")
assert "FM-SURRENDERED smc-1 gen-s1" in result.stdout, result.stdout
state = controller_state()
assert state["queue"]["child-1@gen-c1"]["reparented_to"] == "primary"
assert state["queue"]["child-2@gen-c2"]["reparented_to"] == "primary"
assert "reparented_to" not in state["queue"]["child-done@gen-cd"]
proof = state["workers"][slot]["release_proof"]
assert proof["surrender"]["orphaned_children"] == 2, proof["surrender"]
assert all(v["verdict"] == "surrendered" for v in proof["authorities"].values())

# The idempotent rerun re-issues the stored proof BEFORE the children gate,
# so it needs no orphan flag and restamps nothing.
again = run(*surrender)
assert "already recorded" in again.stdout, again.stdout
assert controller_state()["workers"][slot]["release_proof"] == proof
PY
  pass "surrender refuses live children without the orphan confirmation and durably reparents them with it"
}

childless_surrender_bytes_unchanged() {
  # The orphan count is SCOPED to surrenders that actually orphaned children:
  # every receipt's evidence_digest is taken over the surrender block, so an
  # unconditional "orphaned_children": 0 would move all five digests on the
  # ordinary childless lane that never orphaned anything.
  compartment_fixture_env fm-worker-surrender-childless
  python3 - "$WRAPPER" "$COMPARTMENT_ENVFILE" "$COMPARTMENT_FIXTURE" <<'PY' || fail "a childless surrender no longer mints its original bytes"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, fixture_path = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

run("request", "--task", "task-1", "--task-generation", "gen-1",
    "--home-binding", binding(1001), "--account-binding", binding(2001),
    "--worktree-binding", binding(3001), "--repository-binding", binding(4001),
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())
slot = str(state["queue"]["task-1@gen-1"]["slot"])
fixture = json.loads(Path(fixture_path).read_text())
fixture["workers"][slot]["resources"]["vm"]["power_state"] = "VM deallocated"
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")) + "\n")

# A childless ORDINARY surrender - and the orphan flag is accepted but must
# change nothing, since there is nothing to orphan.
run("surrender", "--task", "task-1", "--task-generation", "gen-1",
    "--reason", "ordinary childless surrender", "--output", str(Path(env["FM_HOME"]) / "s.json"),
    "--confirm-surrender", "--confirm-orphan-children",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
proof = json.loads((Path(env["FM_HOME"]) / "s.json").read_text())
assert "orphaned_children" not in proof["surrender"], proof["surrender"]
assert sorted(proof["surrender"]) == [
    "discarded_unlanded_executions", "last_execution_digest", "ordinary_refusal",
    "power_state", "reason", "surrendered_at",
], sorted(proof["surrender"])

# The receipts are digests of exactly that block, so pinning the block pins
# the bytes: recompute each evidence_digest the way the command does.
import hashlib
for name, receipt in proof["authorities"].items():
    expected = hashlib.sha256(json.dumps(
        {"authority": name, "surrender": proof["surrender"]},
        sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    assert receipt["evidence_digest"] == expected, (name, receipt["evidence_digest"], expected)
PY
  pass "a childless surrender mints its original receipt bytes with no orphan key"
}

secondmate_release_children_positive_control() {
  # The design C item 6 positive control: release refuses under a live child,
  # and FINISHING that child (the ordinary release+reset lane, not a
  # withdrawal) makes the same parent release succeed.
  compartment_fixture_env fm-worker-release-positive
  python3 - "$WRAPPER" "$COMPARTMENT_ENVFILE" <<'PY' || fail "finishing the child did not unlock the parent release"
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

def controller_state():
    return json.loads((Path(env["FM_HOME"]) / "state/azure-workers/controller.json").read_text())

def proved_proof(task, generation, worker, seed):
    proof = {
        "schema": "fm.worker-release/v2", "home_binding": worker["bindings"]["home_binding"],
        "task": task, "task_generation": generation,
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
            "task": task, "task_generation": generation,
            "assignment_generation": worker["assignment_generation"], "verdict": "proved",
            "evidence_digest": binding(offset * 1000 + seed),
        }
        receipt["receipt_digest"] = hashlib.sha256(
            json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        proof["authorities"][authority] = receipt
    proof["proof_digest"] = hashlib.sha256(
        json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    path = Path(env["FM_HOME"]) / "{}-proof.json".format(task)
    path.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
    return str(path)

run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
run("request", "--task", "child-1", "--task-generation", "gen-c1",
    "--home-binding", binding(31), "--account-binding", binding(32),
    "--worktree-binding", binding(33), "--repository-binding", binding(34),
    "--repository-generation", "repo-c1", "--owner-kind", "secondmate", "--eligible",
    "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
parent_worker = state["workers"][str(state["queue"]["smc-1@gen-s1"]["slot"])]
child_worker = state["workers"][str(state["queue"]["child-1@gen-c1"]["slot"])]
parent_proof = proved_proof("smc-1", "gen-s1", parent_worker, 77)

# Live child: the parent release refuses atomically under the lock.
refused = run("release", "--task", "smc-1", "--task-generation", "gen-s1",
              "--proof-file", parent_proof, check=False)
assert refused.returncode != 0, refused.stdout
assert "release refuses: 1 active children name parent smc-1" in refused.stderr, refused.stderr

# FINISH the child: ordinary release, then reconcile to complete (deallocate,
# delete-compute, reset).
child_proof = proved_proof("child-1", "gen-c1", child_worker, 88)
run("release", "--task", "child-1", "--task-generation", "gen-c1", "--proof-file", child_proof)
for _ in range(6):
    run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
    if controller_state()["queue"]["child-1@gen-c1"]["status"] == "complete":
        break
assert controller_state()["queue"]["child-1@gen-c1"]["status"] == "complete"

# The SAME parent proof now releases: the child bound was the only refusal.
run("release", "--task", "smc-1", "--task-generation", "gen-s1", "--proof-file", parent_proof)
assert controller_state()["queue"]["smc-1@gen-s1"]["status"] == "releasing"
PY
  pass "a finished child unlocks the exact parent release the live child refused"
}

compartment_chain_tip_command() {
  # The controller-owned anchor for compartment landing proofs. It is
  # deliberately NOT part of the message lane (PR 3's invariant, pinned by a
  # static test): recording the tip is a lifecycle write, so it is its own
  # command with its own gates.
  compartment_fixture_env fm-worker-chain-tip
  python3 - "$WRAPPER" "$COMPARTMENT_ENVFILE" <<'PY' || fail "the compartment chain tip command is not gated"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

state_path = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"

def controller_state():
    return json.loads(state_path.read_text())

run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("request", "--task", "task-a", "--task-generation", "gen-a",
    "--home-binding", binding(31), "--account-binding", binding(32),
    "--worktree-binding", binding(33), "--repository-binding", binding(34),
    "--repository-generation", "repo-a", "--owner-kind", "primary", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
smc_slot = str(state["queue"]["smc-1@gen-s1"]["slot"])
assignment = state["workers"][smc_slot]["assignment_generation"]
author_assignment = state["workers"][str(state["queue"]["task-a@gen-a"]["slot"])]["assignment_generation"]

def tip(sequence, digest, task="smc-1", generation="gen-s1", asg=None, check=True):
    return run("compartment-chain-tip", "--task", task, "--task-generation", generation,
               "--assignment-generation", asg or assignment,
               "--sequence", str(sequence), "--chain-digest", digest, check=check)

# Records on the WORKER RECORD, under the controller lock.
tip(1, "a" * 64)
recorded = controller_state()["workers"][smc_slot]["verified_chain_tip"]
assert recorded["sequence"] == 1 and recorded["chain_digest"] == "a" * 64, recorded
assert recorded["recorded_at"], recorded

# Monotonic: advancing is fine, rewinding refuses, and a same-sequence fork
# refuses - a tip that could be rewritten freely would be no anchor at all.
tip(2, "b" * 64)
refused = tip(1, "a" * 64, check=False)
assert refused.returncode != 0 and "refuses to rewind" in refused.stderr, refused.stderr
refused = tip(2, "c" * 64, check=False)
assert refused.returncode != 0 and "already recorded a different digest" in refused.stderr, refused.stderr
# An exact replay of the current tip is idempotent.
tip(2, "b" * 64)
assert controller_state()["workers"][smc_slot]["verified_chain_tip"]["sequence"] == 2

# Identity gates.
refused = tip(3, "d" * 64, asg="asg-99999999", check=False)
assert refused.returncode != 0 and "assignment generation is not exact" in refused.stderr, refused.stderr
refused = tip(3, "d" * 64, task="task-a", generation="gen-a", asg=author_assignment, check=False)
assert refused.returncode != 0 and "secondmate compartments only" in refused.stderr, refused.stderr
refused = tip(3, "nothex", check=False)
assert refused.returncode != 0, refused.stderr
refused = tip(0, "d" * 64, check=False)
assert refused.returncode != 0 and "positive integer" in refused.stderr, refused.stderr
refused = tip(3, "d" * 64, task="ghost", generation="gen-x", check=False)
assert refused.returncode != 0 and "exact assigned task generation" in refused.stderr, refused.stderr

# The author worker never gains the field.
assert "verified_chain_tip" not in controller_state()["workers"][
    str(controller_state()["queue"]["task-a@gen-a"]["slot"])]
PY
  pass "the compartment chain tip records on the controller-owned worker record and is monotonic"
}

compartment_status_projection() {
  # PR-6 status projection: every live compartment appears in bounded status
  # from controller.json fields only, additively for JSON consumers.
  compartment_fixture_env fm-worker-compartment-status
  python3 - "$WRAPPER" "$COMPARTMENT_ENVFILE" <<'PY' || fail "the compartment status projection golden failed"
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile = sys.argv[1:]
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        raise AssertionError("{} failed: {}".format(args, result.stderr))
    return result

def binding(number):
    return format(number, "064x")

state_path = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"

def controller_state():
    return json.loads(state_path.read_text())

# An author-only fleet projects an EMPTY compartments section and prints no
# compartment line: the key is additive and the text output is unchanged.
run("request", "--task", "task-1", "--task-generation", "gen-1",
    "--home-binding", binding(11), "--account-binding", binding(12),
    "--worktree-binding", binding(13), "--repository-binding", binding(14),
    "--repository-generation", "repo-1", "--owner-kind", "primary", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
status = json.loads(run("status", "--json").stdout)
assert status["compartments"] == [], status["compartments"]
assert "compartment:" not in run("status").stdout

# One compartment, three lifetime children, one withdrawn: active 2, total 3.
run("request", "--task", "smc-1", "--task-generation", "gen-s1",
    "--home-binding", binding(21), "--account-binding", binding(22),
    "--worktree-binding", binding(23), "--repository-binding", binding(24),
    "--repository-generation", "repo-s1", "--owner-kind", "primary",
    "--role", "secondmate", "--eligible")
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
for number in (1, 2, 3):
    run("request", "--task", "child-{}".format(number), "--task-generation", "gen-c{}".format(number),
        "--home-binding", binding(30 + number * 10), "--account-binding", binding(31 + number * 10),
        "--worktree-binding", binding(32 + number * 10), "--repository-binding", binding(33 + number * 10),
        "--repository-generation", "repo-c{}".format(number), "--owner-kind", "secondmate", "--eligible",
        "--parent-task", "smc-1", "--parent-task-generation", "gen-s1")
run("withdraw", "--task", "child-3", "--task-generation", "gen-c3", "--confirm-withdraw",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])

state = controller_state()
slot = state["queue"]["smc-1@gen-s1"]["slot"]
worker = state["workers"][str(slot)]
status = json.loads(run("status", "--json").stdout)
assert status["compartments"] == [{
    "task": "smc-1", "task_generation": "gen-s1", "status": "assigned",
    "slot": slot, "assignment_generation": worker["assignment_generation"],
    "children_active": 2, "children_total": 3,
    "ttl_anchor": worker["assigned_at"] or worker["created_at"],
}], status["compartments"]
text = run("status").stdout
expected_line = "compartment: task=smc-1@gen-s1 status=assigned slot={} children=2/3 ttl-anchor={}".format(
    slot, worker["assigned_at"] or worker["created_at"])
assert expected_line in text, (expected_line, text)

# session_legs is projected only when a worker record actually carries it
# (the additive design B.2 field): plant it and it appears, JSON and text.
state = controller_state()
state["workers"][str(slot)]["session_legs"] = 5
state_path.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")) + "\n")
status = json.loads(run("status", "--json").stdout)
assert status["compartments"][0]["session_legs"] == 5, status["compartments"]
assert expected_line + " legs=5" in run("status").stdout
PY
  pass "bounded status projects live compartments with children counts, TTL anchor, and optional legs"
}


message_lane_provider_contract() {
  local tmp
  fm_test_tmproot_into tmp fm-message-lane-provider
  python3 - "$AZURE" "$tmp" <<'PY' || fail "message lane provider contract failed"
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

provider_path, tmp = sys.argv[1], Path(sys.argv[2])
os.environ["FM_AZURE_STORAGE_NAME"] = "stfmtestwkr01"
spec = importlib.util.spec_from_file_location("azure_provider", provider_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

SUB = "11111111-1111-4111-8111-111111111111"
controller = {
    "home_binding": "0" * 64, "subscription": SUB,
    "deployment_generation": "dep-one", "owner": "owner", "prefix": "fmtest",
    "resource_group": "rg-fixture",
}
bindings = {
    "home_binding": "1" * 64, "task": "task-msg", "task_generation": "gen-msg",
    "assignment_generation": "asg-00000001", "account_binding": "2" * 64,
    "worktree_binding": "3" * 64, "repository_binding": "4" * 64,
    "repository_generation": "repo-msg",
}
def message(**fields):
    base = {"slot": 3, "role": "author", "cloud_generation": 1, "bindings": bindings}
    base.update(fields)
    return base

store = {}
uploads = []
downloads = {"count": 0}

def entry_for(name, body):
    return {
        "name": name,
        "properties": {"contentLength": len(body)},
        "metadata": {"content_digest": hashlib.sha256(body).hexdigest()},
    }

def fake_az(ctrl, args, check=True, timeout=None):
    if args[:3] == ["storage", "blob", "show"]:
        name = args[args.index("--name") + 1]
        if name not in store:
            return None, 1, "BlobNotFound"
        return entry_for(name, store[name]), 0, ""
    if args[:3] == ["storage", "blob", "upload"]:
        name = args[args.index("--name") + 1]
        store[name] = Path(args[args.index("--file") + 1]).read_bytes()
        uploads.append(name)
        return None, 0, ""
    if args[:3] == ["storage", "blob", "list"]:
        prefix = args[args.index("--prefix") + 1]
        limit = int(args[args.index("--num-results") + 1])
        names = [name for name in sorted(store) if name.startswith(prefix)]
        start = int(args[args.index("--marker") + 1]) if "--marker" in args else 0
        page = [entry_for(name, store[name]) for name in names[start:start + limit]]
        if "--show-next-marker" in args and start + limit < len(names):
            page.append({"nextMarker": str(start + limit)})
        return page, 0, ""
    if args[:3] == ["storage", "blob", "download"]:
        downloads["count"] += 1
        Path(args[args.index("--file") + 1]).write_bytes(store[args[args.index("--name") + 1]])
        return None, 0, ""
    raise AssertionError(args)

module.az = fake_az

def refuses(callable_, needle):
    try:
        callable_()
    except module.ProviderError as exc:
        assert needle in str(exc), (needle, str(exc))
        return
    raise AssertionError("no refusal containing {!r}".format(needle))

# The exact reviewed bounds, and the exact refusal strings derived from them.
assert module.MESSAGE_JSON_MAX_BYTES == 262144
assert module.MESSAGE_ATTACH_MAX_BYTES == 268435456

# JSON lane: content-addressed name, single upload, replay is a no-op success.
payload = json.dumps({"schema": "fm.secondmate-message/v1", "text": "hello"}).encode()
digest = hashlib.sha256(payload).hexdigest()
msg_file = tmp / "msg.json"
msg_file.write_bytes(payload)
result = module.message_put(controller, message(lane="json", file=str(msg_file)))
expected_name = "session/in/{}.json".format(digest)
assert result == {"blob_name": expected_name, "sha256": digest, "bytes": len(payload), "replayed": False}, result
assert uploads == [expected_name] and store[expected_name] == payload
replay = module.message_put(controller, message(lane="json", file=str(msg_file)))
assert replay["replayed"] is True and uploads == [expected_name], (replay, uploads)

# Size bound, JSON requirement, and emptiness all refuse with exact strings
# BEFORE any az call could run.
big = tmp / "big.json"
big.write_bytes(json.dumps("a" * 262200).encode())
refuses(lambda: module.message_put(controller, message(lane="json", file=str(big))),
        "message payload exceeds its 262144-byte bound")
bad = tmp / "bad.json"
bad.write_bytes(b"not json {{{")
refuses(lambda: module.message_put(controller, message(lane="json", file=str(bad))),
        "message payload is not valid JSON")
empty = tmp / "empty.json"
empty.write_bytes(b"")
refuses(lambda: module.message_put(controller, message(lane="json", file=str(empty))),
        "message payload is empty")

# Attach lane: binary content with NO JSON requirement, its own prefix, and a
# bound proven through the constant seam rather than a 256MiB fixture (the
# refusal string derives from the same constant the check reads).
blob = b"\x00\x01\x02binary-not-json\xff" * 8
attach_file = tmp / "delta.bundle"
attach_file.write_bytes(blob)
attach_result = module.message_put(controller, message(lane="attach", file=str(attach_file)))
attach_digest = hashlib.sha256(blob).hexdigest()
assert attach_result["blob_name"] == "session/in/attach/{}.bundle".format(attach_digest), attach_result
original_bound = module.MESSAGE_ATTACH_MAX_BYTES
module.MESSAGE_ATTACH_MAX_BYTES = 4096
try:
    oversized = tmp / "oversized.bundle"
    oversized.write_bytes(b"\xab" * 5000)
    refuses(lambda: module.message_put(controller, message(lane="attach", file=str(oversized))),
            "message attachment exceeds its 4096-byte bound")
finally:
    module.MESSAGE_ATTACH_MAX_BYTES = original_bound

# A name that already exists with bytes other than its own content address is
# corruption or a foreign writer, never a replay. The judgment is the stamped
# content_digest metadata, so a SAME-LENGTH different-bytes blob refuses too,
# and a blob with no digest metadata at all (a foreign writer; this op's own
# uploads always stamp it) refuses rather than reading as a replay.
corrupt_payload = json.dumps({"n": 42}).encode()
corrupt_name = "session/in/{}.json".format(hashlib.sha256(corrupt_payload).hexdigest())
corrupt_file = tmp / "corrupt.json"
corrupt_file.write_bytes(corrupt_payload)
store[corrupt_name] = b"xx"
refuses(lambda: module.message_put(controller, message(lane="json", file=str(corrupt_file))),
        "differs from its content address")
store[corrupt_name] = b"Y" * len(corrupt_payload)
refuses(lambda: module.message_put(controller, message(lane="json", file=str(corrupt_file))),
        "differs from its content address")
def digestless_show(ctrl, args, check=True, timeout=None):
    if args[:3] == ["storage", "blob", "show"]:
        name = args[args.index("--name") + 1]
        return {"properties": {"contentLength": len(store[name])}}, 0, ""
    return fake_az(ctrl, args, check=check, timeout=timeout)
store[corrupt_name] = corrupt_payload
module.az = digestless_show
refuses(lambda: module.message_put(controller, message(lane="json", file=str(corrupt_file))),
        "differs from its content address")
module.az = fake_az
del store[corrupt_name]

# The namespace guard is the enforced boundary for BOTH ops.
assert module.require_session_blob_name("session/out/000001-aa.json", module.MESSAGE_OUTBOX_PREFIX)
refuses(lambda: module.require_session_blob_name("outcome-" + "a" * 32 + ".bundle", module.MESSAGE_OUTBOX_PREFIX),
        "outside the session/ namespace")
refuses(lambda: module.require_session_blob_name("session/out/../../request.json", module.MESSAGE_OUTBOX_PREFIX),
        "outside the session/ namespace")
refuses(lambda: module.require_session_blob_name("session/in/x.json", module.MESSAGE_OUTBOX_PREFIX),
        "outside its session/out/ lane")

# Collect: fetches new outbox blobs, never touches session/in/, and NEVER
# re-downloads collected history: an existing local name is judged against
# the listing's digest metadata without a transfer (the download counter is
# the proof), identical skips, divergent refuses.
store.clear()
uploads.clear()
downloads["count"] = 0
first = json.dumps({"sequence": 1}).encode()
second = json.dumps({"sequence": 2}).encode()
store["session/out/000001-aa.json"] = first
store["session/out/000002-bb.json"] = second
store["session/in/planted.json"] = b"{}"
outdir = tmp / "collected"
outdir.mkdir()
collected = module.message_collect(controller, message(output_dir=str(outdir)))
assert [entry["blob_name"] for entry in collected["fetched"]] == [
    "session/out/000001-aa.json", "session/out/000002-bb.json"], collected
assert collected["skipped"] == []
assert collected["cursor"] == "000002-bb.json" and collected["more"] is False, collected
assert downloads["count"] == 2, downloads
assert sorted(path.name for path in outdir.iterdir()) == ["000001-aa.json", "000002-bb.json"]
assert (outdir / "000001-aa.json").read_bytes() == first
assert collected["fetched"][0]["sha256"] == hashlib.sha256(first).hexdigest()
again = module.message_collect(controller, message(output_dir=str(outdir)))
assert again["fetched"] == [] and len(again["skipped"]) == 2, again
assert again["cursor"] == "000002-bb.json" and again["more"] is False, again
assert downloads["count"] == 2, ("collected history was re-downloaded", downloads)
# Divergence is decided from the digest metadata, also without a transfer.
(outdir / "000001-aa.json").write_bytes(b"locally diverged")
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "collected message blob 000001-aa.json diverges from the existing local file")
assert downloads["count"] == 2, ("a divergence check downloaded the blob", downloads)
(outdir / "000001-aa.json").write_bytes(first)
# The cursor makes the walk incremental: nothing at or before it is touched.
after_cursor = module.message_collect(controller, message(output_dir=str(outdir), after="000001-aa.json"))
assert after_cursor["fetched"] == [] and len(after_cursor["skipped"]) == 1, after_cursor
assert after_cursor["skipped"][0]["blob_name"] == "session/out/000002-bb.json", after_cursor
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir), after="../evil")),
        "message collect cursor is malformed")

# Digestless guest-written blobs (no metadata) are judged by exact size:
# same size skips without a transfer, a size mismatch refuses.
def digestless_list(entries):
    def digestless_az(ctrl, args, check=True, timeout=None):
        if args[:3] == ["storage", "blob", "list"]:
            return entries, 0, ""
        return fake_az(ctrl, args, check=check, timeout=timeout)
    return digestless_az
module.az = digestless_list([
    {"name": "session/out/000001-aa.json", "properties": {"contentLength": len(first)}},
])
digestless = module.message_collect(controller, message(output_dir=str(outdir)))
assert digestless["fetched"] == [] and len(digestless["skipped"]) == 1, digestless
assert downloads["count"] == 2, ("a digestless same-size blob was re-downloaded", downloads)
module.az = digestless_list([
    {"name": "session/out/000001-aa.json", "properties": {"contentLength": len(first) + 7}},
])
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "collected message blob 000001-aa.json diverges from the existing local file")
assert downloads["count"] == 2, downloads
module.az = fake_az

# Cursor pagination collects a mailbox deeper than one call's processing
# page across successive calls (proven through the constant seam), and the
# per-call transfer budget stops a call early with an honest cursor.
paged_store_names = ["session/out/{:08d}-pp.json".format(index) for index in range(1, 6)]
store.clear()
for index, name in enumerate(paged_store_names, 1):
    store[name] = json.dumps({"page_sequence": index}).encode()
paged_dir = tmp / "collected-paged"
paged_dir.mkdir()
original_page = module.MESSAGE_COLLECT_PAGE_BLOBS
module.MESSAGE_COLLECT_PAGE_BLOBS = 2
try:
    page_one = module.message_collect(controller, message(output_dir=str(paged_dir)))
    assert len(page_one["fetched"]) == 2 and page_one["more"] is True, page_one
    assert page_one["cursor"] == "00000002-pp.json", page_one
    page_two = module.message_collect(controller, message(output_dir=str(paged_dir), after=page_one["cursor"]))
    assert len(page_two["fetched"]) == 2 and page_two["more"] is True, page_two
    page_three = module.message_collect(controller, message(output_dir=str(paged_dir), after=page_two["cursor"]))
    assert len(page_three["fetched"]) == 1 and page_three["more"] is False, page_three
finally:
    module.MESSAGE_COLLECT_PAGE_BLOBS = original_page
assert sorted(path.name for path in paged_dir.iterdir()) == [name.split("/")[-1] for name in paged_store_names]

# The marker walk crosses truncated listing pages inside one call: with a
# two-entry listing page the whole five-blob mailbox still collects at once.
marker_dir = tmp / "collected-marker"
marker_dir.mkdir()
original_max = module.MESSAGE_COLLECT_MAX_BLOBS
module.MESSAGE_COLLECT_MAX_BLOBS = 2
try:
    marker_walk = module.message_collect(controller, message(output_dir=str(marker_dir)))
    assert len(marker_walk["fetched"]) == 5 and marker_walk["more"] is False, marker_walk
finally:
    module.MESSAGE_COLLECT_MAX_BLOBS = original_max

# The transfer budget bounds one call's downloads and reports the remainder
# through the cursor instead of refusing or overrunning.
budget_dir = tmp / "collected-budget"
budget_dir.mkdir()
store.clear()
store["session/out/00000001-bg.json"] = b"12345678"
store["session/out/00000002-bg.json"] = b"87654321"
original_budget = module.MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES
module.MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES = 10
try:
    budget_one = module.message_collect(controller, message(output_dir=str(budget_dir)))
    assert len(budget_one["fetched"]) == 1 and budget_one["more"] is True, budget_one
    assert budget_one["cursor"] == "00000001-bg.json", budget_one
    budget_two = module.message_collect(controller, message(output_dir=str(budget_dir), after=budget_one["cursor"]))
    assert len(budget_two["fetched"]) == 1 and budget_two["more"] is False, budget_two
finally:
    module.MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES = original_budget

store.clear()
store["session/out/000001-aa.json"] = first
store["session/out/000002-bb.json"] = second

# A hostile or buggy listing cannot walk the op outside session/out/: foreign
# names, traversal aliases, nested paths, and unbounded sizes all refuse.
real_az = module.az
def hostile(entries):
    def hostile_az(ctrl, args, check=True, timeout=None):
        if args[:3] == ["storage", "blob", "list"]:
            return entries, 0, ""
        return real_az(ctrl, args, check=check, timeout=timeout)
    return hostile_az
module.az = hostile([{"name": "outcome-evil.bundle", "properties": {"contentLength": 3}}])
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "outside the session/ namespace")
module.az = hostile([{"name": "session/out/../request.json", "properties": {"contentLength": 3}}])
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "outside the session/ namespace")
module.az = hostile([{"name": "session/out/nested/blob.json", "properties": {"contentLength": 3}}])
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "message outbox blob name is unsupported")
module.az = hostile([{"name": "session/out/huge.bundle", "properties": {"contentLength": 268435457}}])
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "message outbox blob size is malformed or unbounded")
module.az = real_az

# A symlinked local target is never followed.
os.symlink(tmp / "elsewhere", outdir / "000003-cc.json")
store["session/out/000003-cc.json"] = b"{}"
refuses(lambda: module.message_collect(controller, message(output_dir=str(outdir))),
        "symlinked local target")
(outdir / "000003-cc.json").unlink()
del store["session/out/000003-cc.json"]

# End-to-end dispatch pin: the REAL provider binary routes message-put to the
# same bounded op, and the refusal fires before any az invocation exists to
# fail differently.
env = dict(os.environ)
env.update({
    "FM_AZURE_SUBSCRIPTION_ID": SUB, "FM_AZURE_DEPLOYMENT_GENERATION": "dep-one",
    "FM_AZURE_OWNER_TAG": "owner", "FM_AZURE_NAMING_PREFIX": "fmtest",
    "FM_AZURE_STORAGE_NAME": "stfmtestwkr01",
})
request = {
    "schema": "fm.worker-provider-request/v1", "operation": "message-put",
    "controller": controller, "action": message(lane="json", file=str(big)),
}
proc = subprocess.run(
    [sys.executable, provider_path], input=json.dumps(request).encode(),
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=60,
)
assert proc.returncode == 2, (proc.returncode, proc.stderr)
assert b"AZURE WORKER PROVIDER REFUSED: message payload exceeds its 262144-byte bound" in proc.stderr, proc.stderr
PY
  pass "message lane provider ops bound size, address by content, and hold the session/ boundary"
}

message_lane_claim_exemption() {
  local tmp provider fixture home envfile
  fm_test_tmproot_into tmp fm-message-lane-claim
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

  python3 - "$WRAPPER" "$envfile" "$fixture" "$tmp" <<'PY' || fail "message lane claim exemption failed"
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, envfile, fixture_path, tmp = sys.argv[1:]
tmp = Path(tmp)
env = os.environ.copy()
for line in Path(envfile).read_text().splitlines():
    key, value = line.split("=", 1)
    env[key] = value

def run(*args, check=True, overrides=None):
    call_env = dict(env)
    call_env.update(overrides or {})
    result = subprocess.run(
        [wrapper] + list(args), env=call_env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
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

controller_json = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"

def controller_state():
    return json.loads(controller_json.read_text())

def fixture_state():
    return json.loads(Path(fixture_path).read_text())

def assignment(number):
    state = controller_state()
    item = state["queue"]["task-{}@gen-{}".format(number, number)]
    return item, state["workers"][str(item["slot"])]

request(1)
request(2)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])

# JSON message: content-addressed upload through the CLI, replay converges.
item1, worker1 = assignment(1)
payload = json.dumps({"schema": "fm.secondmate-message/v1", "text": "hi"}).encode()
digest = hashlib.sha256(payload).hexdigest()
message_file = tmp / "message.json"
message_file.write_bytes(payload)
baseline = controller_json.read_bytes()
put = json.loads(run(
    "message-put", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--file", str(message_file),
).stdout)
assert put["blob_name"] == "session/in/{}.json".format(digest) and put["replayed"] is False, put
replay = json.loads(run(
    "message-put", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--file", str(message_file),
).stdout)
assert replay["replayed"] is True, replay
assert put["blob_name"] in fixture_state()["session_blobs"][str(item1["slot"])]

# Attach lane rides the CLI too, into its own prefix, without a JSON body.
attach_file = tmp / "delta.bundle"
attach_file.write_bytes(b"\x00binary\xff" * 4)
attach = json.loads(run(
    "message-put", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--attach", str(attach_file),
).stdout)
assert attach["blob_name"].startswith("session/in/attach/") and attach["blob_name"].endswith(".bundle"), attach

# Collect fetches only session/out/ blobs, skips identical replays, refuses
# divergence, and a planted session/in/ blob never comes home.
fixture = fixture_state()
slot_blobs = fixture["session_blobs"][str(item1["slot"])]
out_one = json.dumps({"sequence": 1}).encode()
out_two = json.dumps({"sequence": 2}).encode()
slot_blobs["session/out/000001-aa.json"] = out_one.hex()
slot_blobs["session/out/000002-bb.json"] = out_two.hex()
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")))
outdir = tmp / "collected"
outdir.mkdir()
collected = json.loads(run(
    "message-collect", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--output-dir", str(outdir),
).stdout)
assert [entry["blob_name"] for entry in collected["fetched"]] == [
    "session/out/000001-aa.json", "session/out/000002-bb.json"], collected
assert sorted(path.name for path in outdir.iterdir()) == ["000001-aa.json", "000002-bb.json"]
again = json.loads(run(
    "message-collect", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--output-dir", str(outdir),
).stdout)
assert again["fetched"] == [] and len(again["skipped"]) == 2, again
assert again["cursor"] == "000002-bb.json" and again["more"] is False, again
resumed = json.loads(run(
    "message-collect", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--output-dir", str(outdir),
    "--after", "000001-aa.json",
).stdout)
assert resumed["fetched"] == [] and len(resumed["skipped"]) == 1, resumed
assert resumed["skipped"][0]["blob_name"] == "session/out/000002-bb.json", resumed
(outdir / "000001-aa.json").write_bytes(b"locally diverged")
diverged = run(
    "message-collect", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", worker1["assignment_generation"], "--output-dir", str(outdir),
    check=False,
)
assert diverged.returncode != 0 and "diverges from the existing local file" in diverged.stderr, diverged.stderr
(outdir / "000001-aa.json").write_bytes(out_one)

# Neither op writes controller state: the durable document is byte-identical
# across every message-lane call above.
assert controller_json.read_bytes() == baseline, "a message op rewrote controller.json"

# THE test proposal A's design would have failed: an outstanding execute
# claim on the slot does not block message delivery. Wedge a durable execute
# claim (the provider result omits the outcome disposition, so its apply
# refuses deterministically and the claim stays), then message-put succeeds
# while a compute-mutating action with the same shape refuses.
staging = tmp / "staging"
payload_dir = staging / "payload"
account_dir = staging / "account"
outcome_dir = staging / "outcome"
for directory in (payload_dir, account_dir, outcome_dir):
    directory.mkdir(parents=True)
(payload_dir / "repo.bundle").write_bytes(b"bundle-fixture")
(payload_dir / "brief.md").write_text("brief\n")
(account_dir / "auth.json").write_text("{}\n")
item2, worker2 = assignment(2)

def execute_two(command, overrides=None):
    return run(
        "execute", "--task", "task-2", "--task-generation", "gen-2",
        "--assignment-generation", worker2["assignment_generation"], "--wall-seconds", "60",
        "--payload-dir", str(payload_dir), "--account-dir", str(account_dir),
        "--outcome-dir", str(outcome_dir),
        "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
        "--", command, check=False, overrides=overrides,
    )

skewed = execute_two("/bin/echo", overrides={"FIXTURE_OMIT_OUTCOME": "1"})
assert skewed.returncode != 0 and "no outcome disposition" in skewed.stderr, skewed.stderr
claimed_state = controller_state()
slot2 = str(item2["slot"])
assert claimed_state["pending_actions"][slot2]["type"] == "execute", claimed_state["pending_actions"]
claimed_bytes = controller_json.read_bytes()

exempt = json.loads(run(
    "message-put", "--task", "task-2", "--task-generation", "gen-2",
    "--assignment-generation", worker2["assignment_generation"], "--file", str(message_file),
).stdout)
assert exempt["blob_name"] == "session/in/{}.json".format(digest), exempt
outdir2 = tmp / "collected-2"
outdir2.mkdir()
collect_exempt = json.loads(run(
    "message-collect", "--task", "task-2", "--task-generation", "gen-2",
    "--assignment-generation", worker2["assignment_generation"], "--output-dir", str(outdir2),
).stdout)
assert collect_exempt["fetched"] == [] and collect_exempt["skipped"] == [], collect_exempt
assert "cursor" in collect_exempt and collect_exempt["more"] is False, collect_exempt
message_calls = [entry for entry in fixture_state()["calls"] if entry["type"] == "message-put"]
assert any(entry["slot"] == item2["slot"] for entry in message_calls), message_calls

# Positive control: a compute-mutating action with the same task shape (a
# fresh argv, so a fresh idempotency key rather than a replay of the wedged
# one) still refuses against the outstanding claim, and the claim survived
# the message traffic untouched.
control = execute_two("/usr/bin/true")
assert control.returncode != 0 and "still has an unapplied execute action" in control.stderr, control.stderr
assert controller_json.read_bytes() == claimed_bytes, "message ops disturbed the durable claim"

# Refusal shapes: unknown or unassigned task, wrong generation, and a
# malformed flag pair all refuse before any provider call.
missing = run("message-put", "--task", "task-9", "--task-generation", "gen-9",
              "--assignment-generation", "asg-00000009", "--file", str(message_file), check=False)
assert missing.returncode != 0 and "requires one exact assigned task generation" in missing.stderr, missing.stderr
wrong_generation = run("message-put", "--task", "task-1", "--task-generation", "gen-1",
                       "--assignment-generation", "asg-99999999", "--file", str(message_file), check=False)
assert wrong_generation.returncode != 0 and "assignment generation is not exact" in wrong_generation.stderr
both = run("message-put", "--task", "task-1", "--task-generation", "gen-1",
           "--assignment-generation", worker1["assignment_generation"],
           "--file", str(message_file), "--attach", str(attach_file), check=False)
assert both.returncode != 0 and "exactly one of --file or --attach" in both.stderr, both.stderr
neither = run("message-put", "--task", "task-1", "--task-generation", "gen-1",
              "--assignment-generation", worker1["assignment_generation"], check=False)
assert neither.returncode != 0 and "exactly one of --file or --attach" in neither.stderr, neither.stderr
PY
  pass "message-put succeeds across an outstanding execute claim; the compute path still refuses"
}

message_lane_static_contract() {
  python3 - "$CONTROLLER" "$AZURE" "$DOC" "$WRAPPER" <<'PY' || fail "message lane static contract failed"
import ast
import re
import sys
from pathlib import Path

controller_src = Path(sys.argv[1]).read_text(encoding="utf-8")
azure_src = Path(sys.argv[2]).read_text(encoding="utf-8")
doc = Path(sys.argv[3]).read_text(encoding="utf-8")
wrapper = Path(sys.argv[4]).read_text(encoding="utf-8")

def node_of(source, name):
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise AssertionError("function {} is absent".format(name))

def segment(source, name):
    return ast.get_source_segment(source, node_of(source, name))

# D.3 static contract: the provider's inventory reads exactly the three NAMED
# per-slot blob records (reservation.json, request.json, result.json) through
# blob_record's exact-name show, and never lists container contents. A future
# contents-sweep edit inside inventory goes red here.
inventory = segment(azure_src, "inventory")
assert inventory.count("blob_record(") == 3, inventory.count("blob_record(")
assert '"reservation.json"' in inventory
assert '"request.json"' in inventory
assert '"result.json"' in inventory
assert '"storage", "blob", "list"' not in inventory
assert '"blob", "list"' not in inventory
assert "list_blobs" not in inventory
blob_record_src = segment(azure_src, "blob_record")
assert '"storage", "blob", "show"' in blob_record_src
assert '"list"' not in blob_record_src

# The carve is dispatched like inventory and never through the mutate path:
# main routes the message verbs raw while mutate alone keeps the landed-code
# gate, and mutate's action-type allowlist cannot reach the message ops.
main_src = segment(azure_src, "main")
assert '"message-put"' in main_src and '"message-collect"' in main_src
assert "require_landed_code()" in main_src
mutate_src = segment(azure_src, "mutate")
assert "message" not in mutate_src
for op_name, lane_marker in (("message_put", "session/in/"), ("message_collect", "session/out/")):
    op_node = node_of(azure_src, op_name)
    docstring = ast.get_docstring(op_node) or ""
    assert "CLAIM-EXEMPT" in docstring, op_name
    assert lane_marker in docstring, op_name
    # The interim role scope (both roles until PR 4 spawns compartments) is
    # stated where the ops live, not discovered in production.
    assert "author-role" in docstring and "PR 4/6" in docstring, op_name
    assert "require_session_blob_name" in segment(azure_src, op_name), op_name
collect_doc = ast.get_docstring(node_of(azure_src, "message_collect")) or ""
assert "never deletes or overwrites" in collect_doc
assert "never re-downloads collected history" in collect_doc
put_doc = ast.get_docstring(node_of(azure_src, "message_put")) or ""
assert "assignment_generation" in put_doc, "the delivery-fencing contract left the put docstring"
module_doc = ast.get_docstring(ast.parse(azure_src)) or ""
assert "assignment_generation" in module_doc, "the delivery-fencing contract left the module docstring"
guard_doc = ast.get_docstring(node_of(azure_src, "require_session_blob_name")) or ""
assert "session/" in guard_doc and "ENFORCED" in guard_doc
# The per-call transfer budget IS the constant the controller sizes the
# subprocess deadline from, and collect never hard-refuses mailbox depth.
assert "MESSAGE_COLLECT_TRANSFER_BUDGET_BYTES = MESSAGE_ATTACH_MAX_BYTES" in azure_src
collect_src = segment(azure_src, "message_collect")
assert "message outbox exceeds" not in collect_src, "the mailbox-depth hard refusal came back"

# Controller side of the carve: the message commands never touch the claim
# machinery or the durable document, and the generic mutate verb still
# refuses outside provider_mutate.
for name in ("message_lane_worker", "command_message_put", "command_message_collect"):
    source = segment(controller_src, name)
    # Call tokens, not bare names: the carve comment inside the command is
    # allowed to NAME the machinery it stays out of; invoking it is what
    # must go red.
    for banned in ("make_action(", "claim_pending(", "apply_pending(", "provider_mutate(",
                   "slot_lease(", "save_state(", '"mutate"'):
        assert banned not in source, (name, banned)
assert 'provider_call(env, "message-put"' in segment(controller_src, "command_message_put")
assert 'provider_call(env, "message-collect"' in segment(controller_src, "command_message_collect")
assert "provider mutations go through provider_mutate with a slot lease" in segment(controller_src, "provider_call")
action_types = re.search(r"ACTION_TYPES = frozenset\(\{(.*?)\}\)", controller_src, re.S)
assert action_types and "message" not in action_types.group(1), "message ops leaked into the claim contract"

# The two size constants stay in step across controller and provider, like
# MAX_OUTCOME_BYTES does with the supervisor.
controller_bound = re.search(r"^MESSAGE_ATTACH_MAX_BYTES = (.+)$", controller_src, re.M)
provider_bound = re.search(r"^MESSAGE_ATTACH_MAX_BYTES = (.+)$", azure_src, re.M)
assert controller_bound and provider_bound and controller_bound.group(1) == provider_bound.group(1)
assert re.search(r"^MESSAGE_JSON_MAX_BYTES = 256 \* 1024$", azure_src, re.M)

# The doc names the carve, verbatim, next to the claim contract.
carve = (
    "The compartment message lane (`message-put`/`message-collect`) is the one provider "
    "operation family outside the per-slot claim contract: bounded, content-addressed, "
    "idempotent data-plane blob transfers that touch no compute, no money, and no lifecycle "
    "state; every compute-mutating action keeps the full claim/lease/fence discipline."
)
lines = doc.splitlines()
carve_index = next(index for index, line in enumerate(lines) if line == carve)
claim_index = next(index for index, line in enumerate(lines) if "pending_actions" in line and "idempotency key" in line)
assert abs(carve_index - claim_index) <= 4, (carve_index, claim_index)

# The wrapper dispatches both verbs through the gated lane. The compartment
# chain tip rides the same gated lane but is NOT part of the carve: it is a
# lifecycle write, which is exactly why it is a separate verb.
assert "|message-put|message-collect|compartment-chain-tip)" in wrapper
assert "compartment-chain-tip" not in carve
PY
  pass "inventory stays three named blob reads; the carve is pinned in code, doc, and wrapper"
}

daily_bound_and_idle_matrix() {
  local tmp
  fm_test_tmproot_into tmp fm-worker-daily-matrix
  python3 - "$CONTROLLER" "$tmp" <<'PY' || fail "daily bound / idle deallocate matrix failed"
import copy
import datetime as dt
import importlib.util
import os
import sys

spec = importlib.util.spec_from_file_location("lifecycle_daily", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
tmp = sys.argv[2]

# --- environment() parsing: absent means the default 100; an explicit zero,
# negative, or non-numeric value refuses LOUDLY instead of meaning unbounded.
os.environ.update({
    "FM_HOME": tmp,
    "FM_AZURE_SUBSCRIPTION_ID": "11111111-1111-4111-8111-111111111111",
    "FM_AZURE_DEPLOYMENT_GENERATION": "dep-one",
    "FM_AZURE_OWNER_TAG": "owner",
    "FM_AZURE_NAMING_PREFIX": "fmtest",
})
for name in (
    "FM_AZURE_WORKER_DAILY_BOUND_USD", "FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE",
    "FM_AZURE_WORKER_IDLE_RELEASE_SECONDS",
):
    os.environ.pop(name, None)
parsed = module.environment()
assert parsed["daily_bound_usd"] == 100.0
assert parsed["daily_bound_override"] is None
assert parsed["idle_release_seconds"] == 14400
for bad in ("0", "-5", "abc", "nan", "inf", ""):
    os.environ["FM_AZURE_WORKER_DAILY_BOUND_USD"] = bad
    try:
        module.environment()
    except module.LifecycleError as exc:
        assert "FM_AZURE_WORKER_DAILY_BOUND_USD" in str(exc), (bad, exc)
    else:
        raise AssertionError("daily bound {} was accepted".format(bad or "empty"))
os.environ["FM_AZURE_WORKER_DAILY_BOUND_USD"] = "250"
os.environ["FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE"] = "2099-01-01"
assert module.environment()["daily_bound_usd"] == 250.0
assert module.environment()["daily_bound_override"] == "2099-01-01"
del os.environ["FM_AZURE_WORKER_DAILY_BOUND_USD"]
del os.environ["FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE"]
for bad in ("599", "604801", "abc", "4h"):
    os.environ["FM_AZURE_WORKER_IDLE_RELEASE_SECONDS"] = bad
    try:
        module.environment()
    except module.LifecycleError as exc:
        # Non-numeric values refuse through the loud LifecycleError lane,
        # never a raw ValueError traceback.
        assert "FM_AZURE_WORKER_IDLE_RELEASE_SECONDS" in str(exc), (bad, exc)
    else:
        raise AssertionError("idle release seconds {} was accepted".format(bad))
os.environ["FM_AZURE_WORKER_IDLE_RELEASE_SECONDS"] = "600"
assert module.environment()["idle_release_seconds"] == 600
del os.environ["FM_AZURE_WORKER_IDLE_RELEASE_SECONDS"]

# --- baseline roll: relative times only, never a hardcoded wall-clock date.
T0 = module.now_utc()
T1 = T0 + dt.timedelta(days=1)
day0 = module.utc_day(T0)
day1 = module.utc_day(T1)
assert day0 != day1
state = {}
day, spend = module.daily_spend_evidence(state, 50.0, T0)
assert day == day0 and spend == 0.0
assert state["daily_cost_baseline"] == {"utc_day": day0, "actual_usd_at_day_start": 50.0}
day, spend = module.daily_spend_evidence(state, 80.0, T0)
assert spend == 30.0
assert state["daily_cost_baseline"]["actual_usd_at_day_start"] == 50.0
day, spend = module.daily_spend_evidence(state, 80.0, T1)
assert day == day1 and spend == 0.0
assert state["daily_cost_baseline"] == {"utc_day": day1, "actual_usd_at_day_start": 80.0}
# A downward ACM revision clamps at zero rather than going negative.
assert module.daily_spend_evidence(state, 70.0, T1)[1] == 0.0
# Unreadable actual: no spend evidence, and the good baseline is not clobbered.
kept = copy.deepcopy(state["daily_cost_baseline"])
assert module.daily_spend_evidence(state, None, T1)[1] is None
assert module.daily_spend_evidence(state, True, T1)[1] is None
assert state["daily_cost_baseline"] == kept

# --- the bound refusal: exact day, spend, and bound; override for the exact
# current day only; unreadable actual fails closed.
denv = {"daily_bound_usd": 100.0, "daily_bound_override": None}
state = {"daily_cost_baseline": {"utc_day": day0, "actual_usd_at_day_start": 50.0}}
refusal, override_day = module.daily_bound_refusal(denv, state, 160.0, now=T0)
assert override_day is None
assert refusal == (
    "daily spend bound: day {} recorded spend 110.00 USD reached the 100.00 USD "
    "daily bound; new compute and reservations (create/resume/capacity-reserve) "
    "are refused, wind-down stays allowed; "
    "set FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} to admit past the bound "
    "for this day only".format(day0, day0)
), refusal
assert module.daily_bound_refusal(denv, state, 149.99, now=T0) == (None, None)
right = dict(denv, daily_bound_override=day0)
refusal, override_day = module.daily_bound_refusal(right, state, 160.0, now=T0)
assert refusal is None and override_day == day0
# The CHECK never records override use - only record_daily_override_use does,
# after the admission decision, so a later cumulative refusal cannot leave a
# false "used" claim behind.
assert "daily_bound_override_used" not in state, state["daily_bound_override_used"]
module.record_daily_override_use(right, state, 160.0, day0, now=T0)
assert state["daily_bound_override_used"]["utc_day"] == day0
assert state["daily_bound_override_used"]["recorded_day_spend_usd"] == 110.0
assert state["daily_bound_override_used"]["bound_usd"] == 100.0
wrong = dict(denv, daily_bound_override=day1)
refusal, override_day = module.daily_bound_refusal(wrong, state, 160.0, now=T0)
assert refusal is not None and override_day is None
assert "FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} does not name today".format(day1) in refusal
refusal, override_day = module.daily_bound_refusal(denv, state, None, now=T0)
assert refusal is not None and "unreadable" in refusal and override_day is None

# --- scaffolding for planner-level scenarios (the classification matrix's
# exact-resource construction).
penv = {
    "max_workers": 16, "planning_hours": 3500.0, "policy_phase": "commissioning",
    "commissioning_ceiling_usd": 1500.0, "steady_target_usd": 1000.0,
    "admission_hours": 24.0, "cooldown_seconds": 300, "warm_idle": 0,
    "idle_release_seconds": 14400, "daily_bound_usd": 100.0, "daily_bound_override": None,
    "deployment_generation": "dep", "owner": "owner",
}
def build_assigned(slot):
    build_state = {
        "queue": {}, "workers": {}, "completed_worker_seconds": 0.0,
        "cleanup_refusals": [], "next_assignment": 1, "pending_actions": {},
        "capacity_reservations": {},
    }
    item = {
        "schema": module.REQUEST_SCHEMA, "task": "task-idle", "task_generation": "gen-idle",
        "repository_generation": "repo-gen", "home_binding": "1" * 64,
        "account_binding": "2" * 64, "worktree_binding": "3" * 64,
        "repository_binding": "4" * 64, "owner_kind": "primary", "role": "author",
        "eligible": True, "discretionary": True, "status": "assigned",
        "enqueued_at": module.iso_utc(T0 - dt.timedelta(days=2)),
    }
    worker = module.create_worker_record(penv, build_state, slot, item, 10.0)
    tags = module.expected_tags(worker)
    resources = {}
    for kind in module.REQUIRED_RESOURCE_KINDS:
        resources[kind] = {
            "id": "/slot/{}/{}".format(slot, kind), "immutable_id": "immutable-" + kind,
            "tags": dict(tags),
        }
    resources["vm"]["power_state"] = "VM running"
    resources["nic"]["attached_to"] = resources["vm"]["id"]
    for kind in ("os-disk", "task-disk", "account-disk"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    cloud = {"slot": slot, "resources": resources}
    worker["resources"] = {
        kind: module.resource_identity(value) for kind, value in resources.items()
    }
    worker["cloud_instance_id"] = resources["vm"]["immutable_id"]
    worker["phase"] = "assigned"
    worker["assigned_at"] = module.iso_utc(T0 - dt.timedelta(days=2))
    item["slot"] = slot
    item["assignment_generation"] = worker["assignment_generation"]
    build_state["workers"][str(slot)] = worker
    build_state["queue"][worker["queue_key"]] = item
    inventory = {
        "metrics": {"actual_usd": 10.0, "forecast_usd": 20.0},
        "workers": [cloud], "capacity_reservations": [], "conflicts": [],
    }
    return build_state, worker, item, cloud, inventory

# --- idle deallocate: provable end-of-task signals only, at the threshold and
# never before, never with a claim, never on already-dark compute.
istate, worker, item, cloud, inventory = build_assigned(1)
assert module.idle_deallocate_due(penv, istate, worker, cloud, now=T0) is False  # never executed
worker["last_execution_at"] = module.iso_utc(T0 - dt.timedelta(seconds=14399))
assert module.idle_deallocate_due(penv, istate, worker, cloud, now=T0) is False  # not yet due
worker["last_execution_at"] = module.iso_utc(T0 - dt.timedelta(seconds=14400))
assert module.idle_deallocate_due(penv, istate, worker, cloud, now=T0) is True   # exactly due
action = module.next_reconcile_action(penv, istate, inventory, now=T0)
assert action["type"] == "deallocate" and action.get("idle_release") is True, action
claimed = copy.deepcopy(istate)
claimed["pending_actions"]["1"] = {"type": "execute", "slot": 1}
assert module.next_reconcile_action(penv, claimed, inventory, now=T0) is None
finished = copy.deepcopy(istate)
finished["queue"][worker["queue_key"]]["status"] = "releasing"
assert module.idle_deallocate_due(
    penv, finished, finished["workers"]["1"], cloud, now=T0) is False
dark_cloud = copy.deepcopy(cloud)
dark_cloud["resources"]["vm"]["power_state"] = "VM deallocated"
assert module.idle_deallocate_due(penv, istate, worker, dark_cloud, now=T0) is False
dark_inventory = dict(inventory, workers=[dark_cloud])
assert module.next_reconcile_action(penv, istate, dark_inventory, now=T0) is None

# --- steer counts as recency: a worker steered minutes ago is being actively
# driven and must NOT be deallocated, however old its last execution is;
# an old steer does not shield it.
worker["last_execution_at"] = module.iso_utc(T0 - dt.timedelta(seconds=50000))
worker["last_steer_at"] = module.iso_utc(T0 - dt.timedelta(seconds=60))
assert module.idle_deallocate_due(penv, istate, worker, cloud, now=T0) is False
assert module.next_reconcile_action(penv, istate, inventory, now=T0) is None
worker["last_steer_at"] = module.iso_utc(T0 - dt.timedelta(seconds=15000))
assert module.idle_deallocate_due(penv, istate, worker, cloud, now=T0) is True
del worker["last_steer_at"]

# --- override use is an EFFECT, recorded only when admission actually admits:
# bound tripped + override named + cumulative admission refusing must leave no
# durable "used" claim behind.
create_metrics = {
    "actual_usd": 1499.0, "forecast_usd": 1499.0,
    "regional_limit_vcpus": 128, "regional_used_vcpus": 2,
    "specialized_active_vcpus": 0, "specialized_active_by_family": {},
    "family_limit_vcpus": {family: 10 for _, family in module.SKU_PLAN.values()},
    "family_used_vcpus": {family: 0 for _, family in module.SKU_PLAN.values()},
    "family_free_vcpus": {family: 10 for _, family in module.SKU_PLAN.values()},
    "sku_hourly_usd": {sku: 0.25 for sku, _ in module.SKU_PLAN.values()},
}
create_inventory = {
    "metrics": create_metrics, "workers": [], "capacity_reservations": [], "conflicts": [],
}
oenv = dict(penv, daily_bound_override=day0)
create_state = {
    "queue": {}, "workers": {}, "completed_worker_seconds": 0.0,
    "cleanup_refusals": [], "next_assignment": 1, "pending_actions": {},
    "capacity_reservations": {},
    "daily_cost_baseline": {"utc_day": day0, "actual_usd_at_day_start": 0.0},
}
queued = {
    "schema": module.REQUEST_SCHEMA, "task": "task-bound", "task_generation": "gen-bound",
    "repository_generation": "repo-gen", "home_binding": "6" * 64,
    "account_binding": "7" * 64, "worktree_binding": "8" * 64,
    "repository_binding": "9" * 64, "owner_kind": "primary", "role": "author",
    "eligible": True, "discretionary": True, "status": "queued",
    "enqueued_at": module.iso_utc(T0),
}
create_state["queue"][module.request_key("task-bound", "gen-bound")] = queued
refused_create = module.next_reconcile_action(oenv, create_state, create_inventory, now=T0)
assert refused_create["type"] == "admission-refused", refused_create
assert "daily spend bound" not in refused_create["reason"], refused_create["reason"]
assert "daily_bound_override_used" not in create_state, create_state["daily_bound_override_used"]
# With cumulative room the same override admits, the action carries the day,
# and the use is recorded as an effect.
create_metrics["actual_usd"] = 500.0
create_metrics["forecast_usd"] = 500.0
admitted_create = module.next_reconcile_action(oenv, create_state, create_inventory, now=T0)
assert admitted_create["type"] == "create", admitted_create
assert admitted_create.get("daily_bound_override") == day0
assert create_state["daily_bound_override_used"]["utc_day"] == day0

# --- the cooldown stamp: a release-proved worker whose VM is ALREADY dark but
# whose cooldown_started_at is null gets stamped once at first observation, so
# delete-compute becomes due after cooldown_seconds instead of never
# (live: slot 1, d2-probe-20260819).
cstate, cworker, citem, ccloud, cinventory = build_assigned(2)
cworker["release_proof"] = {"proof_digest": "5" * 64}
cworker["released_at"] = module.iso_utc(T0 - dt.timedelta(hours=1))
cworker["phase"] = "release-proved"
cworker["cooldown_started_at"] = None
citem["status"] = "releasing"
ccloud["resources"]["vm"]["power_state"] = "VM deallocated"
cinventory = dict(cinventory, workers=[ccloud])
assert module.next_reconcile_action(penv, cstate, cinventory, now=T0) is None
assert cworker["cooldown_started_at"] == module.iso_utc(T0), cworker["cooldown_started_at"]
assert module.next_reconcile_action(penv, cstate, cinventory, now=T0) is None
assert cworker["cooldown_started_at"] == module.iso_utc(T0)
later = T0 + dt.timedelta(seconds=penv["cooldown_seconds"] + 1)
due = module.next_reconcile_action(penv, cstate, cinventory, now=later)
assert due is not None and due["type"] == "delete-compute", due
assert due["release_proof_digest"] == "5" * 64
PY
  pass "daily bound refuses exactly, override binds to the exact day, idle deallocate gates on provable signals, and the cooldown stamp lands once"
}

daily_bound_cli() {
  local tmp provider fixture home attempt result
  for attempt in 1 2; do
    fm_test_tmproot_into tmp fm-worker-daily-cli
    provider="$tmp/provider.py"
    fixture="$tmp/provider-state.json"
    home="$tmp/home"
    mkdir -p "$home"
    write_fixture_provider "$provider"
    set +e
    env \
      FM_HOME="$home" \
      FM_AZURE_SUBSCRIPTION_ID="$SUB" \
      FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
      FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
      FIXTURE_STATE="$fixture" \
      FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1 \
      python3 - "$WRAPPER" "$fixture" <<'PY'
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, fixture_path = sys.argv[1:]
env = dict(os.environ)

def today():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%d")

DAY = today()
YESTERDAY = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).strftime("%Y-%m-%d")

def day_guard():
    # A UTC midnight crossing mid-unit makes every day-bound expectation
    # ambiguous; exit 99 so the harness reruns once on a fresh fixture.
    if today() != DAY:
        sys.exit(99)

def run(*args, check=True, overrides=None):
    call_env = dict(env)
    call_env.update(overrides or {})
    result = subprocess.run([wrapper] + list(args), env=call_env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if check and result.returncode != 0:
        day_guard()
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
    return json.loads(Path(fixture_path).read_text())

def set_actual(value):
    fixture = fixture_state()
    fixture["metrics"]["actual_usd"] = value
    fixture["metrics"]["forecast_usd"] = value
    Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")))

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
    run("release", "--task", proof["task"], "--task-generation", proof["task_generation"],
        "--proof-file", str(path))

# 1. First reconcile of the day snapshots the baseline at the fixture's 100.
request(1)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
day_guard()
baseline = controller_state()["daily_cost_baseline"]
assert baseline == {"utc_day": DAY, "actual_usd_at_day_start": 100.0}, baseline

# 2. Recorded day spend of 200 crosses the default 100 bound: a new create is
# refused with the EXACT string naming the day, the spend, and the bound.
set_actual(300.0)
request(2)
plan = json.loads(run("reconcile", "--apply", "--json",
                      "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
day_guard()
refused = [entry for entry in plan["actions"] if entry["type"] == "admission-refused"]
assert refused, plan["actions"]
expected = (
    "daily spend bound: day {} recorded spend 200.00 USD reached the 100.00 USD "
    "daily bound; new compute and reservations (create/resume/capacity-reserve) "
    "are refused, wind-down stays allowed; "
    "set FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} to admit past the bound "
    "for this day only".format(DAY, DAY)
)
assert refused[0]["reason"] == expected, refused[0]["reason"]
assert len(controller_state()["workers"]) == 1, "the bound built capacity anyway"
assert plan["status"]["daily_bound_tripped"] is True, plan["status"]

# 3. Wind-down is never blocked by the tripped bound: release, deallocate,
# delete-compute, and reset all still plan and apply.
release(1)
plan = json.loads(run("reconcile", "--apply", "--json",
                      "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
day_guard()
types = [entry["type"] for entry in plan["actions"]]
for wind_down in ("deallocate", "delete-compute", "reset"):
    assert wind_down in types, (wind_down, types)
assert types[-1] == "admission-refused", types
assert controller_state()["workers"] == {}, "wind-down did not complete under the bound"
assert fixture_state()["workers"] == {}, "cloud capacity survived wind-down under the bound"

# 4. A wrong-day override still refuses, loudly naming the mismatch.
wrong = json.loads(run(
    "reconcile", "--json",
    overrides={"FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE": YESTERDAY},
).stdout)
day_guard()
assert wrong["actions"][0]["type"] == "admission-refused"
assert "FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE={} does not name today".format(
    YESTERDAY) in wrong["actions"][0]["reason"], wrong["actions"][0]["reason"]

# 5. The exact-current-day override admits, is printed loudly, is carried on
# the action, and is recorded durably.
overridden = run("reconcile", "--apply",
                 "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
                 overrides={"FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE": DAY})
day_guard()
assert "DAILY BOUND OVERRIDE" in overridden.stdout, overridden.stdout
state = controller_state()
assert len(state["workers"]) == 1
assert state["daily_bound_override_used"]["utc_day"] == DAY, state.get("daily_bound_override_used")
status = run("status")
assert "DAILY BOUND OVERRIDE USED" in status.stdout, status.stdout
status_json = json.loads(run("status", "--json").stdout)
assert status_json["daily_bound_override_used"]["utc_day"] == DAY
assert status_json["daily_bound_usd"] == 100.0

# 6. Resume is compute-resuming, so the same bound guards it: refuse without
# the override, admit loudly with it.
slot = str(controller_state()["queue"]["task-2@gen-2"]["slot"])
fixture = fixture_state()
for kind in ("vm", "nic", "os-disk"):
    fixture["workers"][slot]["resources"].pop(kind)
Path(fixture_path).write_text(json.dumps(fixture, sort_keys=True, separators=(",", ":")))
blocked = run("resume", "--task", "task-2", "--task-generation", "gen-2",
              "--repository-binding", binding(4002),
              "--confirm-resume", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
              check=False)
day_guard()
assert blocked.returncode == 2, (blocked.returncode, blocked.stderr)
assert "daily spend bound: day {} recorded spend 200.00 USD".format(DAY) in blocked.stderr, blocked.stderr
assert controller_state()["workers"][slot]["cloud_generation"] == 1
resumed = run("resume", "--task", "task-2", "--task-generation", "gen-2",
              "--repository-binding", binding(4002),
              "--confirm-resume", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
              overrides={"FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE": DAY})
day_guard()
assert "DAILY BOUND OVERRIDE" in resumed.stdout, resumed.stdout
assert controller_state()["workers"][slot]["cloud_generation"] == 2

# 6b. Specialized reservations are the runner's AUTOMATIC lane, so the exact
# same bound gates capacity-reserve and capacity-reserve-shape with the exact
# same string; the exact-day override admits and records; capacity-release is
# wind-down and is never blocked.
fence = "a" * 64
blocked_reserve = json.loads(run(
    "capacity-reserve", "--reservation-id", "azr-daily0000001", "--fence-binding", fence,
    "--role", "validation", "--sku", "Standard_D4as_v7", "--sku-family", "StandardDasv7Family",
    "--vcpus", "4", "--amount-usd", "25",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
day_guard()
assert blocked_reserve["status"] == "queued", blocked_reserve
assert blocked_reserve["reason"] == expected, blocked_reserve["reason"]
blocked_shape = json.loads(run(
    "capacity-reserve-shape", "--shape-id", "shape-daily", "--fence-binding", fence,
    "--constituent",
    "reservation-id=azr-daily0000002,role=validation,sku=Standard_D4as_v7,"
    "sku-family=StandardDasv7Family,vcpus=4,amount-usd=25",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
day_guard()
assert blocked_shape["status"] == "queued", blocked_shape
assert blocked_shape["reason"] == expected, blocked_shape["reason"]
reserved = json.loads(run(
    "capacity-reserve", "--reservation-id", "azr-daily0000001", "--fence-binding", fence,
    "--role", "validation", "--sku", "Standard_D4as_v7", "--sku-family", "StandardDasv7Family",
    "--vcpus", "4", "--amount-usd", "25",
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
    overrides={"FM_AZURE_WORKER_DAILY_BOUND_OVERRIDE": DAY}).stdout)
day_guard()
assert reserved["status"] == "reserved", reserved
assert reserved["daily_bound_override"] == DAY, reserved
assert controller_state()["daily_bound_override_used"]["utc_day"] == DAY
run("capacity-release", "--reservation-id", "azr-daily0000001", "--fence-binding", fence,
    "--cleanup-receipt", "b" * 64,
    "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
day_guard()
assert controller_state()["capacity_reservations"]["azr-daily0000001"]["status"] == "released", (
    "capacity-release was blocked by the tripped daily bound")

# 7. The durable baseline rolls when the observed UTC day changes: a stale
# yesterday baseline is re-snapshotted at the current actual, so the new day
# starts at zero recorded spend.
state_file = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"
state = controller_state()
state["daily_cost_baseline"] = {"utc_day": YESTERDAY, "actual_usd_at_day_start": 0.0}
state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
run("reconcile", "--json")
day_guard()
rolled = controller_state()["daily_cost_baseline"]
assert rolled == {"utc_day": DAY, "actual_usd_at_day_start": 300.0}, rolled

# 8. Explicit zero, negative, or non-numeric bound values refuse loudly.
for bad in ("0", "-1", "unbounded"):
    broken = run("status", overrides={"FM_AZURE_WORKER_DAILY_BOUND_USD": bad}, check=False)
    assert broken.returncode == 2 and "FM_AZURE_WORKER_DAILY_BOUND_USD" in broken.stderr, (
        bad, broken.returncode, broken.stderr)
PY
    result=$?
    set -e
    if [ "$result" -eq 0 ]; then
      pass "daily bound refuses new compute exactly, keeps wind-down flowing, and admits only through the exact-day override"
      return 0
    fi
    if [ "$result" -ne 99 ]; then
      fail "daily bound CLI exercise failed"
    fi
    # exit 99: UTC midnight crossed mid-unit; retry once on a fresh fixture.
    echo "# daily bound CLI attempt $attempt crossed UTC midnight; retrying on a fresh fixture" >&2
  done
  fail "daily bound CLI exercise crossed UTC midnight twice"
}

idle_deallocate_cli() {
  local tmp provider fixture home
  fm_test_tmproot_into tmp fm-worker-idle-cli
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
    FM_AZURE_WORKER_IDLE_RELEASE_SECONDS=600 \
    FM_WORKER_PROVIDER_COMMAND="python3 $provider" \
    FIXTURE_STATE="$fixture" \
    FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1 \
    python3 - "$WRAPPER" "$fixture" <<'PY' || fail "idle deallocate CLI exercise failed"
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

wrapper, fixture_path = sys.argv[1:]
env = dict(os.environ)

def run(*args, check=True):
    result = subprocess.run([wrapper] + list(args), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
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

state_file = None
def controller_state():
    return json.loads(state_file.read_text())

def fixture_state():
    return json.loads(Path(fixture_path).read_text())

def stamp(seconds_ago):
    value = dt.datetime.now(dt.timezone.utc) - dt.timedelta(seconds=seconds_ago)
    return value.replace(microsecond=0).isoformat().replace("+00:00", "Z")

def set_last_execution(slot, seconds_ago):
    state = controller_state()
    state["workers"][slot]["last_execution_at"] = stamp(seconds_ago)
    state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))

state_file = Path(env["FM_HOME"]) / "state/azure-workers/controller.json"

# An assigned worker whose recorded execution finished long ago.
request(1)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
slot = str(state["queue"]["task-1@gen-1"]["slot"])
generation = state["workers"][slot]["assignment_generation"]
run("execute", "--task", "task-1", "--task-generation", "gen-1",
    "--assignment-generation", generation, "--wall-seconds", "60",
    "--confirm-execute", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"],
    "--", "/usr/bin/true")
assert controller_state()["workers"][slot]["last_execution_at"]

# Boundary: below the threshold nothing is deallocated.
set_last_execution(slot, 60)
plan = json.loads(run("reconcile", "--apply", "--json",
                      "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
assert not [entry for entry in plan["actions"] if entry["type"] == "deallocate"], plan["actions"]
assert "deallocated" not in fixture_state()["workers"][slot]["resources"]["vm"]["power_state"].lower()

# A recent steer counts as recency: a worker being actively driven is never
# deallocated, however old its last execution.
state = controller_state()
state["workers"][slot]["last_execution_at"] = stamp(4000)
state["workers"][slot]["last_steer_at"] = stamp(30)
state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
plan = json.loads(run("reconcile", "--apply", "--json",
                      "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
assert not [entry for entry in plan["actions"] if entry["type"] == "deallocate"], plan["actions"]
assert "deallocated" not in fixture_state()["workers"][slot]["resources"]["vm"]["power_state"].lower()
state = controller_state()
del state["workers"][slot]["last_steer_at"]
state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))

# A non-numeric idle threshold refuses through the loud lane, never a raw
# traceback.
env_bad = dict(env, FM_AZURE_WORKER_IDLE_RELEASE_SECONDS="abc")
broken = subprocess.run([wrapper, "status"], env=env_bad, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert broken.returncode == 2, (broken.returncode, broken.stderr)
assert "FM_AZURE_WORKER_IDLE_RELEASE_SECONDS" in broken.stderr, broken.stderr
assert "Traceback" not in broken.stderr, broken.stderr

# Past the threshold the planner deallocates unattended - dark compute, never
# a machine-minted release - and marks the worker durably.
set_last_execution(slot, 4000)
applied = run("reconcile", "--apply", "--json",
              "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
plan = json.loads(applied.stdout)
idle_actions = [entry for entry in plan["actions"] if entry["type"] == "deallocate"]
assert idle_actions and idle_actions[0].get("idle_release") is True, plan["actions"]
assert "deallocated" in fixture_state()["workers"][slot]["resources"]["vm"]["power_state"].lower()
state = controller_state()
assert state["workers"][slot]["phase"] == "deallocated"
assert state["workers"][slot]["idle_deallocated_at"]
assert state["workers"][slot]["release_proof"] is None, "idle deallocate minted a release"
assert state["queue"]["task-1@gen-1"]["status"] == "assigned", "idle deallocate completed the task"

# Status LOUDLY lists the idle-deallocated worker until a human releases it.
status_json = json.loads(run("status", "--json").stdout)
listed = status_json["idle_deallocated_workers"]
assert listed and listed[0]["slot"] == int(slot) and listed[0]["task"] == "task-1", listed
status_text = run("status").stdout
assert "IDLE-DEALLOCATED WORKER" in status_text and "RELEASE IT PROPERLY" in status_text, status_text

# Already-dark compute is not deallocated again.
repeat = json.loads(run("reconcile", "--apply", "--json",
                        "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
assert not [entry for entry in repeat["actions"] if entry["type"] == "deallocate"], repeat["actions"]

# A worker with no recorded execution is never idle-deallocated, however old.
request(2)
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
slot2 = str(state["queue"]["task-2@gen-2"]["slot"])
state["workers"][slot2]["assigned_at"] = stamp(90000)
state["workers"][slot2].pop("last_execution_at", None)
state_file.write_text(json.dumps(state, sort_keys=True, separators=(",", ":")))
plan = json.loads(run("reconcile", "--apply", "--json",
                      "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"]).stdout)
assert not [entry for entry in plan["actions"] if entry["type"] == "deallocate"], plan["actions"]
assert "deallocated" not in fixture_state()["workers"][slot2]["resources"]["vm"]["power_state"].lower()

# The ordinary human-driven release path still owns destruction afterwards.
state = controller_state()
worker = state["workers"][slot]
proof = {
    "schema": "fm.worker-release/v2", "home_binding": worker["bindings"]["home_binding"],
    "task": "task-1", "task_generation": "gen-1",
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
        "evidence_digest": binding(offset * 1000 + 1),
    }
    receipt["receipt_digest"] = hashlib.sha256(
        json.dumps(receipt, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    proof["authorities"][authority] = receipt
canonical = json.dumps(proof, sort_keys=True, separators=(",", ":")).encode()
proof["proof_digest"] = hashlib.sha256(canonical).hexdigest()
proof_path = Path(env["FM_HOME"]) / "proof-1.json"
proof_path.write_text(json.dumps(proof, sort_keys=True, separators=(",", ":")))
run("release", "--task", "task-1", "--task-generation", "gen-1", "--proof-file", str(proof_path))
run("reconcile", "--apply", "--confirm-subscription", env["FM_AZURE_SUBSCRIPTION_ID"])
state = controller_state()
assert slot not in state["workers"], "the released idle worker was not reset"
assert state["queue"]["task-1@gen-1"]["status"] == "complete"
assert json.loads(run("status", "--json").stdout)["idle_deallocated_workers"] == []
PY
  pass "idle workers deallocate unattended at the threshold, are loudly listed, and still exit through the ordinary release"
}

compartment_payload_contract() {
  # The producer (bin/fm-spawn.sh) and this validator encode the same contract.
  # They drifted once: fm-spawn.sh staged the compartment session runner and pi
  # extension, PAYLOAD_FILE_BOUNDS admitted neither, and every compartment leg
  # dispatch refused with "payload staging entry is not in the reviewed set".
  # The first block is the structural guard that makes that drift a red test
  # instead of a booted VM that cannot work.
  python3 - "$CONTROLLER" "$ROOT/bin/fm-spawn.sh" "$ROOT/bin/fm-secondmate-cloud-monitor.sh" \
    <<'PY' || fail "compartment payload contract failed"
import hashlib
import importlib.util
import re
import sys
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("lifecycle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
spawn = Path(sys.argv[2]).read_text(encoding="utf-8")
monitor = Path(sys.argv[3]).read_text(encoding="utf-8")

# STRUCTURAL GUARD, FAIL CLOSED: every basename bin/fm-spawn.sh writes into the
# cloud payload directory must be admitted by the compartment bounds.
#
# SCOPE: this is a DRIFT DETECTOR, not the security control. It reads text, so
# any staging that refers to the directory as a whole (tar -C, cd, cp -R src/.,
# a variable alias) is invisible to it; it fails closed on the ones it can see
# but cannot claim to see all of them. The control that actually bounds what
# reaches a guest is staged_directory_manifest at dispatch, which refuses an
# unadmitted entry however it was spelled.
#
# This classifies EVERY occurrence of the payload directory and refuses the ones
# it cannot read, because a guard whose silence is ambiguous between "nothing
# unadmitted" and "I could not parse that" is not a control at all. An earlier
# version matched only a literal basename written straight after the literal
# directory path, so `.../cloud-payload/$NAME` and the ordinary
# `cp src .../cloud-payload/` idiom both slipped past it while it printed green.
# The authoritative check is effect-shaped and lives in
# tests/fm-secondmate-cloud-monitor.test.sh, which runs this same validator over
# the directory a real fm-spawn.sh actually produced; this one is the cheap
# static companion that names the offending line.
spawn_lines = spawn.splitlines()
staged_names = set()
unreadable = []
for site in re.finditer(r"\.cloud-payload", spawn):
    tail = spawn[site.end():]
    if tail[:1] == '"':
        # The directory as a WHOLE. Today's sites are install -d, rm -rf and
        # --payload-dir, none of which stage a file. That is a property of the
        # current callers, NOT of the form: `tar -C <dir>`, `cd <dir>`, and
        # `cp -R src/. <dir>` all name the directory this way and DO stage.
        # This guard cannot see those, which is why it is a drift detector and
        # not the control. The control is staged_directory_manifest at dispatch,
        # and the effect-shaped check in the compartment monitor suite.
        continue
    named = re.match(r"/([A-Za-z0-9][A-Za-z0-9._-]*)\"", tail)
    if named:
        staged_names.add(named.group(1))
        continue
    number = spawn.count("\n", 0, site.start()) + 1
    unreadable.append("  line {}: {}".format(number, spawn_lines[number - 1].strip()))
assert not unreadable, (
    "the payload staging guard cannot classify these bin/fm-spawn.sh sites, so "
    "it cannot prove what gets staged. Fail closed rather than pass blind; use a "
    "literal basename or teach the guard:\n" + "\n".join(unreadable))
assert staged_names, "no payload staging destinations found in bin/fm-spawn.sh"
unbounded = sorted(staged_names - set(module.COMPARTMENT_PAYLOAD_FILE_BOUNDS))
assert not unbounded, (
    "bin/fm-spawn.sh stages payload entries the reviewed set does not admit: "
    "{}".format(unbounded))

# THIRD ENCODING: the compartment monitor's leg argv names these same two files
# by absolute guest path. Producer, validator and consumer are three places
# holding one contract, which is exactly the shape that drifted; the monitor
# suite pins the argv literally, and this pins it to the reviewed set.
argv_names = set(re.findall(r"/mnt/task/\.fm-task/([A-Za-z0-9][A-Za-z0-9._-]*)", monitor))
assert argv_names, "no leg argv payload paths found in bin/fm-secondmate-cloud-monitor.sh"
argv_unbounded = sorted(argv_names - set(module.COMPARTMENT_PAYLOAD_FILE_BOUNDS))
assert not argv_unbounded, (
    "the compartment leg argv names files the reviewed set does not admit, so "
    "the guest would be told to run something that never travels: {}".format(
        argv_unbounded))
# ...and the reverse: a file the argv names must actually be staged.
argv_unstaged = sorted(argv_names - staged_names)
assert not argv_unstaged, (
    "the compartment leg argv names files bin/fm-spawn.sh does not stage: "
    "{}".format(argv_unstaged))
# The guard is only meaningful while it actually sees the compartment pair.
for name in ("fm-secondmate-session.py", "fm-secondmate-spawn.pi-ext.ts"):
    assert name in staged_names, (
        "guard is vacuous: bin/fm-spawn.sh no longer stages {}".format(name))

# Every admitted entry must really fit under its bound at today's size, so a
# bound is never quietly set below the file it is meant to admit.
for name in ("fm-secondmate-session.py", "fm-secondmate-spawn.pi-ext.ts"):
    assert name in module.COMPARTMENT_PAYLOAD_FILE_BOUNDS, (
        "the compartment reviewed set does not admit {}".format(name))
    actual = (Path(sys.argv[2]).parent / name).stat().st_size
    bound = module.COMPARTMENT_PAYLOAD_FILE_BOUNDS[name]
    assert actual <= bound, "{} is {} bytes, over its {}-byte bound".format(
        name, actual, bound)

# LANE SPLIT: the ordinary crewmate lane is exactly as narrow as before.
assert module.payload_contract("author") == (
    module.PAYLOAD_FILE_BOUNDS, module.PAYLOAD_REQUIRED)
assert set(module.PAYLOAD_FILE_BOUNDS) == {"repo.bundle", "brief.md"}
assert module.payload_contract("secondmate") == (
    module.COMPARTMENT_PAYLOAD_FILE_BOUNDS, module.COMPARTMENT_PAYLOAD_REQUIRED)


def stage(names):
    root = Path(tempfile.mkdtemp(prefix="fm-payload-contract-"))
    for name, size in names.items():
        (root / name).write_bytes(bytes((index % 251) for index in range(size)))
    return root


def manifest(role, root):
    bounds, required = module.payload_contract(role)
    return module.staged_directory_manifest(
        "payload", root, bounds=bounds, required=required)


def refusal(role, root):
    try:
        manifest(role, root)
    except module.LifecycleError as exc:
        return str(exc)
    raise AssertionError("payload was accepted but should have been refused")


# Sizes measured on the live azaccept compartment payload.
LIVE = {
    "brief.md": 4384,
    "repo.bundle": 10042238,
    "fm-secondmate-session.py": 45142,
    "fm-secondmate-spawn.pi-ext.ts": 3867,
}

import copy
import hashlib
import importlib.util
import sys

provider_spec = importlib.util.spec_from_file_location(
    "fm_provider_abandon", str(Path(sys.argv[1]).with_name("fm-azure-worker-provider.py")))
provider = importlib.util.module_from_spec(provider_spec)
provider_spec.loader.exec_module(provider)
lifecycle_spec = importlib.util.spec_from_file_location("fm_lifecycle_abandon", sys.argv[1])
lifecycle = importlib.util.module_from_spec(lifecycle_spec)
lifecycle_spec.loader.exec_module(lifecycle)

controller = {
    "subscription": "00000000-0000-4000-8000-000000000000",
    "resource_group": "rg-test", "prefix": "fmtest", "owner": "owner",
    "deployment_generation": "dep-one", "home_binding": "a" * 64,
}
bindings = {
    "home_binding": "a" * 64, "task": "never-started",
    "task_generation": "spawn:never-started", "assignment_generation": "asg-00000038",
    "account_binding": "b" * 64, "worktree_binding": "c" * 64,
    "repository_binding": "d" * 64, "repository_generation": "e" * 40,
}
action = {
    "type": "execute", "slot": 6, "role": "author",
    "sku": "Standard_D4s_v6", "sku_family": "StandardDsv6Family",
    "deployment_generation": "dep-one", "owner": "owner", "cloud_generation": 1,
    "cloud_instance_id": "vm-instance", "bindings": bindings,
    "request_digest": "5" * 64, "reservation_usd": 2.5,
}
action["request"] = dict(bindings, **{
    "schema": "fm.worker-execution/v1", "cloud_instance_id": "vm-instance",
    "argv": ["/usr/bin/true"], "wall_seconds": 60,
    "request_digest": action["request_digest"],
})
tags = provider.action_tags(controller, action)
resources = {}
for kind in provider.REQUIRED_RESOURCE_KINDS:
    resources[kind] = {
        "id": "/resource/" + kind, "immutable_id": "/resource/" + kind,
        "tags": dict(tags),
    }
resources["vm"]["power_state"] = "VM deallocated"
resources["vm"]["immutable_id"] = action["cloud_instance_id"]
for kind in ("monitor-extension", "bootstrap-command", "task-command", "ttl-schedule"):
    resources[kind]["attached_to"] = resources["vm"]["id"]
for kind in ("monitor-extension", "bootstrap-command", "task-command"):
    resources[kind]["provisioning_state"] = "Succeeded"
resources["ttl-schedule"].update({"status": "Enabled", "deadline": "2359"})
for kind, payload in provider.initial_execute_staging_pair(action).items():
    body = provider.canonical_bytes(payload) + b"\n"
    resources[kind].update({"digest": hashlib.sha256(body).hexdigest(), "length": len(body)})
reservation_body = b"{}\n"
resources["global-reservation"].update({
    "digest": hashlib.sha256(reservation_body).hexdigest(), "length": len(reservation_body),
})
action["resources"] = {
    kind: {"id": value["id"], "immutable_id": value["immutable_id"]}
    for kind, value in resources.items()
}
action["idempotency_key"] = hashlib.sha256(provider.canonical_bytes(action)).hexdigest()
tags = provider.action_tags(controller, action)
for resource in resources.values():
    resource["tags"] = dict(tags)
worker = {"slot": 6, "resources": resources}
original_worker = copy.deepcopy(worker)
state = {"worker": worker, "views": 0, "marks": 0, "deletes": 0}

provider.inventory = lambda *_args, **_kwargs: {
    "workers": [copy.deepcopy(state["worker"])], "conflicts": [], "metrics": {},
}
provider.show_full = lambda *_args, **_kwargs: {
    "id": action["resources"]["task-command"]["id"],
    "properties": {"source": None, "provisioningState": "Succeeded"},
    "tags": dict(tags),
}
def pending_view(*_args, **_kwargs):
    state["views"] += 1
    return {
        "executionState": "Pending", "exitCode": 0, "startTime": None,
        "endTime": None, "output": "", "error": "", "executionMessage": None,
    }
provider.run_command_instance_view = pending_view
def mark(_controller, _action, key, value):
    assert key == provider.EXECUTE_ABANDON_MARKER
    assert value == action["idempotency_key"]
    state["marks"] += 1
    state["worker"]["resources"]["state-container"]["tags"][key] = value
provider.mark_cleanup_container = mark
provider.conditional_delete = lambda *_args, **_kwargs: (_ for _ in ()).throw(
    AssertionError("never-started retirement tried to mutate a deallocated VM child"))

result = provider.abandon_execute(controller, action)
assert state == {"worker": state["worker"], "views": 2, "marks": 1, "deletes": 0}, state
assert result["action"] == "abandon-execute"
assert result["execution"]["disposition"] == "provider-never-started-retired"
assert result["worker"]["resources"]["task-command"]["id"] == (
    action["resources"]["task-command"]["id"])
lifecycle.validate_abandon_execute_result(action, result)
for label, mutate in (
    ("VM resource ID", lambda value: value["worker"]["resources"]["vm"].update(
        {"id": "/foreign/vm"})),
    ("VM immutable identity", lambda value: value["worker"]["resources"]["vm"].update(
        {"immutable_id": "foreign-vm"})),
    ("state container ID", lambda value: value["worker"]["resources"]["state-container"].update(
        {"id": "/foreign/container"})),
    ("assignment tag", lambda value: value["worker"]["resources"]["vm"]["tags"].update(
        {"task-binding": "foreign-task"})),
):
    foreign = copy.deepcopy(result)
    mutate(foreign)
    try:
        lifecycle.validate_abandon_execute_result(action, foreign)
    except lifecycle.LifecycleError:
        pass
    else:
        raise AssertionError("retirement accepted a foreign {}".format(label))

# Once marked, every ordinary execute is fenced before submission.
try:
    provider.mutate_execute(controller, action)
except provider.ProviderError as exc:
    assert "fenced by retired never-started claim" in str(exc), exc
else:
    raise AssertionError("a retired execute marker allowed another guest submission")

# The controller-carried key is independently permanent: a supported resume
# may rebuild cloud metadata, but must never make the retired execute runnable.
state["worker"]["resources"]["state-container"]["tags"].pop(
    provider.EXECUTE_ABANDON_MARKER)
durable_only_action = copy.deepcopy(action)
durable_only_action["retired_execute_key"] = action["idempotency_key"]
empty_show = provider.show_full
provider.show_full = lambda *_args, **_kwargs: (_ for _ in ()).throw(
    AssertionError("durably retired execute reached a terminal probe or submission"))
try:
    provider.mutate_execute(controller, durable_only_action)
except provider.ProviderError as exc:
    assert "fenced by retired never-started claim" in str(exc), exc
else:
    raise AssertionError("a durable retired key allowed another guest submission")
provider.show_full = empty_show
state["worker"]["resources"]["state-container"]["tags"][
    provider.EXECUTE_ABANDON_MARKER] = action["idempotency_key"]

# Crash replay after marker landing is terminal and performs no new mutation.
replayed = provider.abandon_execute(controller, action)
assert replayed["execution"] == result["execution"]
assert state["views"] == 4 and state["marks"] == 1 and state["deletes"] == 0, state

# Any evidence of execution keeps custody and does not mark or delete.
state["worker"] = copy.deepcopy(original_worker)
state["views"] = state["marks"] = state["deletes"] = 0
provider.run_command_instance_view = lambda *_args, **_kwargs: {
    "executionState": "Running", "exitCode": 0, "output": "", "error": "",
}
try:
    provider.abandon_execute(controller, action)
except provider.ProviderError as exc:
    assert "never-started" in str(exc), exc
else:
    raise AssertionError("a Running execute was retired")
assert state["marks"] == 0 and state["deletes"] == 0, state

# Ordinary cleanup may accept the missing child only with the exact marker and
# controller-carried retired key; absence alone remains fail closed.
state["worker"]["resources"].pop("task-command")
delete_action = dict(action, type="delete-compute", retired_execute_key=None)
delete_action["idempotency_key"] = "9" * 64
try:
    provider.mutate_delete_compute(controller, delete_action)
except provider.ProviderError as exc:
    assert "custody proof" in str(exc), exc
else:
    raise AssertionError("compute cleanup accepted an unexplained missing task-command")
ORDINARY = {"brief.md": 4384, "repo.bundle": 10042238}

# A compartment payload is admitted, and the manifest carries all four entries
# with their exact digests and byte counts.
compartment = manifest("secondmate", stage(LIVE))
assert sorted(compartment) == sorted(LIVE), sorted(compartment)
for name, size in LIVE.items():
    body = bytes((index % 251) for index in range(size))
    assert compartment[name] == {
        "sha256": hashlib.sha256(body).hexdigest(), "bytes": size}, compartment[name]

# The ordinary crewmate payload is unchanged: same two entries, same digests.
ordinary = manifest("author", stage(ORDINARY))
assert sorted(ordinary) == ["brief.md", "repo.bundle"], sorted(ordinary)
assert all(ordinary[name] == compartment[name] for name in ORDINARY), ordinary

# ...and the crewmate lane is NOT widened: a session runner staged onto an
# ordinary worker is still refused, exactly as on the base revision.
assert "not in the reviewed set: fm-secondmate-session.py" in refusal(
    "author", stage(LIVE))

# REQUIRED, not merely admitted: the leg argv runs the runner and passes
# --pi-ext, so a compartment missing either file refuses at the controller
# rather than dispatching a leg that cannot work.
for name in ("fm-secondmate-session.py", "fm-secondmate-spawn.pi-ext.ts"):
    partial = {key: value for key, value in LIVE.items() if key != name}
    assert "lacks required {}".format(name) in refusal(
        "secondmate", stage(partial))

# Byte bounds still bind on the new entries.
for name, bound in (("fm-secondmate-session.py", 256 * 1024),
                    ("fm-secondmate-spawn.pi-ext.ts", 64 * 1024)):
    assert module.COMPARTMENT_PAYLOAD_FILE_BOUNDS[name] == bound
    oversize = dict(LIVE, **{name: bound + 1})
    assert "exceeds its byte bound: {}".format(name) in refusal(
        "secondmate", stage(oversize))

# An unreviewed name is still refused in the compartment lane too: the fix
# widened the set by exactly two names, it did not open the lane.
assert "not in the reviewed set: id_rsa" in refusal(
    "secondmate", stage(dict(LIVE, **{"id_rsa": 64})))
PY
  pass "the compartment payload lane admits exactly what fm-spawn.sh stages, requires it, and leaves the crewmate lane narrow"
}

static_contract
service_complete_front_door
service_complete_replay_contract
compartment_payload_contract
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
capacity_reserve_inventory_does_not_hold_controller_lock
capacity_release_inventory_does_not_hold_controller_lock
surrender_lane
surrender_refuses_when_ordinary_authority_passes
surrender_refusal_matrix
legacy_scalar_migration
state_fence_and_revision_cas
concurrent_mutations_do_not_serialize
wedged_slot_does_not_stop_the_fleet
secondmate_role_bounds
compartment_child_task_home
local_secondmate_lane_bytes_unchanged
verify_state_home_fence_golden
compartment_child_reaches_its_ordinary_exit
task_home_registry_is_read_by_the_canonical_reader
task_home_marker_matches_the_home_rules
surrender_orphan_confirm
childless_surrender_bytes_unchanged
secondmate_release_children_positive_control
compartment_status_projection
compartment_chain_tip_command
message_lane_provider_contract
message_lane_claim_exemption
message_lane_static_contract
daily_bound_and_idle_matrix
daily_bound_cli
idle_deallocate_cli

echo "# fm-worker-lifecycle.test.sh: all assertions passed"
