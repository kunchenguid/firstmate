#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Focused hermetic regression for semantic Azure assignment ages, one-shot stale
# wakes, paid-idle classification, and inert recovery of a deallocated create.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROLLER="$ROOT/bin/fm-worker-lifecycle.py"
MONITOR="$ROOT/bin/fm-spawn-cloud-monitor.sh"
SUB=11111111-1111-4111-8111-111111111111

assignment_projection_contract() {
  python3 - "$CONTROLLER" <<'PY' || fail "semantic assignment projection failed"
import copy
import datetime as dt
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("assignment_lifecycle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

T0 = dt.datetime(2026, 9, 1, 3, 0, tzinfo=dt.timezone.utc)
env = {"prework_stale_seconds": {
    "queued-no-compute": 1800,
    "creating-compute": 900,
    "compute-running-unassigned": 300,
    "assigned-execute-not-started": 300,
}}
item = {
    "task": "paid-idle", "task_generation": "gen-1", "status": "queued",
    "enqueued_at": "2026-09-01T02:00:00Z",
}
state = {"queue": {"paid-idle@gen-1": item}, "workers": {}, "pending_actions": {}}
queued = module.assignment_projection(env, state, item, now=T0)
assert queued["state"] == "queued-no-compute"
assert queued["since_source"] == "queue.enqueued_at"
assert queued["stale"] is True

item["status"] = "assigning"
item["slot"] = 1
worker = {
    "slot": 1,
    "queue_key": "paid-idle@gen-1",
    "phase": "creating",
    "created_at": "2026-09-01T02:30:00Z",
    "assigned_at": None,
    "assignment_generation": "asg-00000001",
}
state["workers"]["1"] = worker
state["pending_actions"]["1"] = {
    "type": "create", "idempotency_key": "a" * 64,
}
creating = module.assignment_projection(env, state, item, now=T0)
assert creating["state"] == "creating-compute"
assert creating["age_seconds"] == 1800
assert creating["since_source"] == "worker.created_at"

module.resources_exact = lambda *_args, **_kwargs: (True, "")
cloud = {"slot": 1, "resources": {"vm": {"power_state": "VM running"}}}
inventory = {"workers": [cloud]}
paid_idle = module.assignment_projection(env, state, item, inventory=inventory, now=T0)
assert paid_idle["state"] == "compute-running-unassigned", paid_idle
assert paid_idle["billable_idle"] is True
assert paid_idle["working_crewmate"] is False
assert paid_idle["agent_execution_started"] is False
assert paid_idle["stale"] is True
# Repainting does not move the durable transition: a later poll only increases
# its age, reproducing the failure where fresh display heartbeats hid hours of
# paid compute with no agent work.
later = module.assignment_projection(
    env, state, item, inventory=inventory, now=T0 + dt.timedelta(seconds=30)
)
assert later["since"] == paid_idle["since"]
assert later["age_seconds"] == paid_idle["age_seconds"] + 30
assert later["stale"] is True

# A real transition resets age to assigned_at rather than inheriting the old
# create clock.
item["status"] = "assigned"
worker["phase"] = "assigned"
worker["assigned_at"] = "2026-09-01T02:59:50Z"
state["pending_actions"] = {}
assigned = module.assignment_projection(env, state, item, now=T0)
assert assigned["state"] == "assigned-execute-not-started"
assert assigned["since_source"] == "worker.assigned_at"
assert assigned["age_seconds"] == 10
assert assigned["stale"] is False

worker["execute_started_at"] = "2026-09-01T02:59:55Z"
state["pending_actions"]["1"] = {"type": "execute", "idempotency_key": "b" * 64}
executing = module.assignment_projection(env, state, item, now=T0)
assert executing["state"] == "execute-running"
assert executing["since_source"] == "worker.execute_started_at"
assert executing["working_crewmate"] is True

state["pending_actions"] = {}
worker["last_execution_at"] = "2026-09-01T03:00:00Z"
worker["last_execution_digest"] = "c" * 64
returned = module.assignment_projection(env, state, item, now=T0)
assert returned["state"] == "progress-or-result-returned"

item["status"] = "releasing"
worker["released_at"] = "2026-09-01T03:00:01Z"
worker["release_proof"] = {"proof_digest": "d" * 64}
releasing = module.assignment_projection(env, state, item, now=T0 + dt.timedelta(seconds=2))
assert releasing["state"] == "releasing"

item["status"] = "retained"
worker["phase"] = "retained"
worker["release_proof"] = None
worker["last_refusal"] = {"at": "2026-09-01T03:00:02Z"}
retained = module.assignment_projection(env, state, item, now=T0 + dt.timedelta(seconds=3))
assert retained["state"] == "retained-for-investigation"
assert retained["since_source"] == "worker.last_refusal.at"

# Dark never-assigned compute is retained, not dispatched or called working.
item["status"] = "assigning"
worker.update({"phase": "creating", "assigned_at": None, "last_refusal": None})
worker.pop("last_execution_at", None)
worker.pop("last_execution_digest", None)
state["pending_actions"]["1"] = {"type": "create", "idempotency_key": "e" * 64}
dark = copy.deepcopy(cloud)
dark["resources"]["vm"]["power_state"] = "VM deallocated"
dark_projection = module.assignment_projection(
    env, state, item, inventory={"workers": [dark]}, now=T0
)
assert dark_projection["state"] == "retained-for-investigation"
assert dark_projection["working_crewmate"] is False
assert dark_projection["billable_idle"] is False
PY
  pass "controller timestamps distinguish every assignment and execution transition"
}

one_shot_stale_wake_contract() {
  local tmp home state lifecycle snapshot out rc lines
  fm_test_tmproot_into tmp fm-azure-assignment-stale
  home="$tmp/home"
  state="$home/state"
  mkdir -p "$state"
  lifecycle="$tmp/assignment-status"
  snapshot="$tmp/snapshot.json"
  cat > "$lifecycle" <<'SH'
#!/usr/bin/env bash
cat "${FM_TEST_ASSIGNMENT_SNAPSHOT:?}"
SH
  chmod +x "$lifecycle"
  cat > "$snapshot" <<'JSON'
{"age_seconds":7200,"billable_idle":true,"queue_status":"assigning","since":"2026-09-01T00:53:00Z","stale":true,"stale_threshold_seconds":300,"state":"compute-running-unassigned"}
JSON
  printf 'window=default:w-paid:p-idle\n' > "$state/paid-idle.meta"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CLOUD_ASSIGNMENT_LIFECYCLE_COMMAND="$lifecycle" \
    FM_TEST_ASSIGNMENT_SNAPSHOT="$snapshot" \
    FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$MONITOR" paid-idle gen-1 2>&1)
  rc=$?
  set -e
  expect_code 75 "$rc" "the stale monitor must exit after its durable wake: $out"
  assert_contains "$out" "state=compute-running-unassigned age=7200s since=2026-09-01T00:53:00Z" \
    "the monitor rendered repaint age instead of the controller transition"
  assert_contains "$out" "IDLE BILLABLE COMPUTE" \
    "running compute without an agent was not reported as paid idle capacity"
  assert_contains "$out" "route through stuck-crewmate-recovery" \
    "the stale wake did not name the existing recovery path"
  assert_contains "$out" "repeated display heartbeats can hide hours of paid compute with no agent work" \
    "the test does not name the prevented paid-idle heartbeat failure"
  assert_grep "$(printf '\tstale\tdefault:w-paid:p-idle\t')" "$state/.wake-queue" \
    "the monitor did not append an actionable stale wake for the task window"
  lines=$(wc -l < "$state/.wake-queue" | tr -d '[:space:]')
  expect_code 1 "$lines" "the first stale state appended more than one wake"

  set +e
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CLOUD_ASSIGNMENT_LIFECYCLE_COMMAND="$lifecycle" \
    FM_TEST_ASSIGNMENT_SNAPSHOT="$snapshot" \
    FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$MONITOR" paid-idle gen-1 2>&1)
  rc=$?
  set -e
  expect_code 75 "$rc" "the repeated unchanged monitor must stop without repainting: $out"
  assert_contains "$out" "wake was already emitted" \
    "the repeated unchanged state did not consume its durable one-shot receipt"
  lines=$(wc -l < "$state/.wake-queue" | tr -d '[:space:]')
  expect_code 1 "$lines" "an unchanged stale poll spammed an equivalent wake"
  pass "unchanged paid-idle heartbeats produce one actionable stale recovery wake"
}

retained_create_recovery_contract() {
  python3 - "$CONTROLLER" "$SUB" <<'PY' || fail "retained create recovery contract failed"
import argparse
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location("retain_lifecycle", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
subscription = sys.argv[2]

with tempfile.TemporaryDirectory() as root_text:
    root = Path(root_text)
    state_dir = root / "state"
    state_dir.mkdir()
    env = {
        "home": root,
        "home_binding": "1" * 64,
        "subscription": subscription,
        "deployment_generation": "dep-one",
        "owner": "owner",
        "prefix": "fmtest",
        "state_dir": state_dir,
        "state_path": state_dir / "controller.json",
        "lock_path": state_dir / ".lock",
        "slot_lock_dir": state_dir / "slots",
    }
    state = module.empty_state(env)
    item = {
        "schema": module.REQUEST_SCHEMA,
        "task": "never-started",
        "task_generation": "gen-1",
        "repository_generation": "repo-1",
        "home_binding": "1" * 64,
        "account_binding": "2" * 64,
        "worktree_binding": "3" * 64,
        "repository_binding": "4" * 64,
        "owner_kind": "primary",
        "role": "author",
        "eligible": True,
        "status": "assigning",
        "enqueued_at": "2026-09-01T00:53:00Z",
    }
    worker = module.create_worker_record(env, state, 1, item, 1.0)
    state["queue"]["never-started@gen-1"] = item
    state["workers"]["1"] = worker
    action = module.make_action(
        env, "create", worker=worker, item=item, reuse_retained=False
    )
    state["pending_actions"]["1"] = copy.deepcopy(action)
    module.save_json_atomic(env["state_path"], state)

    tags = module.expected_tags(worker)
    resources = {
        kind: {
            "id": "/fixture/{}".format(kind),
            "immutable_id": "{}-immutable".format(kind),
            "tags": copy.deepcopy(tags),
        }
        for kind in module.REQUIRED_RESOURCE_KINDS
    }
    resources["vm"]["power_state"] = "VM deallocated"
    cloud = {"slot": 1, "resources": resources}
    provider_mutations = []

    def provider_call(_env, operation, action=None):
        assert operation == "inventory"
        assert action is None
        return {"inventory": {"workers": [cloud], "conflicts": [], "metrics": {}}}

    def forbidden_mutation(*args, **kwargs):
        provider_mutations.append((args, kwargs))
        raise AssertionError("retained recovery submitted a provider mutation")

    module.provider_call = provider_call
    module.provider_mutate = forbidden_mutation
    args = argparse.Namespace(
        task="never-started",
        task_generation="gen-1",
        slot="1",
        idempotency_key=action["idempotency_key"],
        confirm_retain=True,
        confirm_subscription=subscription,
    )
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        module.command_retain_create(env, args)
    assert "FM-RETAINED-CREATE" in output.getvalue()
    durable = json.loads(env["state_path"].read_text())
    assert durable["queue"]["never-started@gen-1"]["status"] == "retained"
    assert durable["workers"]["1"]["phase"] == "retained"
    assert durable["workers"]["1"]["assigned_at"] is None
    assert durable["workers"]["1"]["last_refusal"]["at"]
    assert "retained_at" not in durable["workers"]["1"]
    assert durable["pending_actions"]["1"] == action, (
        "safe recovery changed or discarded the exact pending create claim"
    )
    assert provider_mutations == []

    # The current retained incident can also present as a successful complete
    # inventory with no exact worker and no slot conflict after dark compute is
    # removed. That proof must be inert too, not a reason to replay create.
    item2 = dict(item, task="now-absent", task_generation="gen-2", status="assigning")
    worker2 = module.create_worker_record(env, durable, 2, item2, 1.0)
    durable["queue"]["now-absent@gen-2"] = item2
    durable["workers"]["2"] = worker2
    action2 = module.make_action(
        env, "create", worker=worker2, item=item2, reuse_retained=False
    )
    durable["pending_actions"]["2"] = copy.deepcopy(action2)
    module.save_json_atomic(env["state_path"], durable)
    args2 = argparse.Namespace(
        task="now-absent", task_generation="gen-2", slot="2",
        idempotency_key=action2["idempotency_key"], confirm_retain=True,
        confirm_subscription=subscription,
    )
    with contextlib.redirect_stdout(io.StringIO()):
        module.command_retain_create(env, args2)
    absent_durable = json.loads(env["state_path"].read_text())
    assert absent_durable["queue"]["now-absent@gen-2"]["status"] == "retained"
    assert absent_durable["pending_actions"]["2"] == action2

    drained, refusals = module.drain_pending(env, strict=False)
    assert drained == []
    assert len(refusals) == 2
    assert all("will not replay during reconcile" in entry["reason"] for entry in refusals)
    assert provider_mutations == []
    after_reconcile = json.loads(env["state_path"].read_text())
    assert after_reconcile["pending_actions"]["1"] == action
    assert after_reconcile["pending_actions"]["2"] == action2
PY
  pass "deallocated never-started creates retain task state and exact claims without replay"
}

cloud_state_receipt_cleanup_contract() {
  local tmp state id
  fm_test_tmproot_into tmp fm-azure-stale-receipt-cleanup
  state="$tmp/state"
  id=paid-idle
  mkdir -p "$state"
  printf 'gen-1|compute-running-unassigned|2026-09-01T00:53:00Z\n' \
    > "$state/$id.cloud-stale-wake"
  # shellcheck source=bin/fm-cloud-state-lib.sh
  . "$ROOT/bin/fm-cloud-state-lib.sh"
  fm_cloud_state_remove "$state" "$id"
  assert_absent "$state/$id.cloud-stale-wake" \
    "the per-generation stale wake receipt survived cloud-state cleanup"
  pass "cloud generation cleanup removes the stale wake receipt"
}

assignment_projection_contract
one_shot_stale_wake_contract
retained_create_recovery_contract
cloud_state_receipt_cleanup_contract
