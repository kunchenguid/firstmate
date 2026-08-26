#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior: reusable host-owned Pi profile snapshots for Azure worker requests.
# Placement load-balances usable profiles through sixteen concurrent requests,
# gives every request a private writable projection, preserves replay identity,
# and cleans only the exact projection its queue entry owns.
#
# EVERY unit runs against an explicit fixture provider AND a fake `az` that
# records any invocation and fails; each unit asserts the fixture was the one
# used and that no cloud call was attempted. A suite here that silently resolved
# the real Azure provider would create billable infrastructure.
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CONTROLLER="$ROOT/bin/fm-worker-lifecycle.py"
SUB=11111111-1111-4111-8111-111111111111

# --- fixtures ---------------------------------------------------------------

# A provider that records every operation it is asked for and answers the
# minimum the controller verifies. It is the ONLY provider any unit may reach;
# `placement_world` asserts that after every run.
write_recording_provider() {
  cat >"$1" <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import sys

request = json.loads(sys.stdin.read())
controller = request["controller"]
log = Path(os.environ["PROVIDER_CALL_LOG"])
with log.open("a", encoding="utf-8") as handle:
    handle.write(request["operation"] + "\n")
response = {
    "schema": "fm.worker-provider-response/v1",
    "operation": request["operation"],
    "controller": controller,
}
if request["operation"] == "inventory":
    # The SKU/family table is read from the controller itself rather than
    # copied, so a plan change cannot leave this fixture quietly admitting
    # against families the real one no longer has.
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "fm_worker_lifecycle", os.environ["CONTROLLER_PATH"])
    lifecycle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lifecycle)
    families = {family for _, family in lifecycle.SKU_PLAN.values()}
    response["inventory"] = {
        "schema": "fm.worker-provider-inventory/v1",
        "workers": [],
        "capacity_reservations": [],
        "conflicts": [],
        "metrics": {
            "actual_usd": 1.0, "forecast_usd": 2.0,
            "regional_limit_vcpus": 128, "regional_used_vcpus": 0,
            "specialized_active_vcpus": 0, "specialized_active_by_family": {},
            "family_limit_vcpus": {family: 40 for family in families},
            "family_used_vcpus": {family: 0 for family in families},
            "family_free_vcpus": {family: 40 for family in families},
            "sku_hourly_usd": {sku: 0.25 for sku, _ in lifecycle.SKU_PLAN.values()},
        },
    }
elif request["operation"] == "mutate":
    action = request["action"]
    # The real provider recomputes this over the whole action and refuses a
    # mismatch. A fixture that skipped it would be MORE permissive than the
    # callee it stands in for, and would hide a controller bug.
    expected = hashlib.sha256(json.dumps(
        {name: value for name, value in action.items() if name != "idempotency_key"},
        sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    if action["idempotency_key"] != expected:
        sys.stderr.write("FIXTURE PROVIDER REFUSED: idempotency key is not exact\n")
        raise SystemExit(1)
    if action["type"] != "create":
        sys.stderr.write(
            "FIXTURE PROVIDER REFUSED: this suite only creates, never {}\n".format(
                action["type"]))
        raise SystemExit(1)
    bindings = action["bindings"]
    secondmate = action.get("role") == "secondmate"
    tags = {
        "workload": "firstmate",
        "firstmate-role": "secondmate-compartment" if secondmate else "worker",
        "deployment-generation": action["deployment_generation"],
        "cleanup-owner": action["owner"], "worker-slot": str(action["slot"]),
        "home-binding": bindings["home_binding"], "task-binding": bindings["task"],
        "task-generation": bindings["task_generation"],
        "assignment-generation": bindings["assignment_generation"],
        "account-binding": bindings["account_binding"],
        "worktree-binding": bindings["worktree_binding"],
        "repository-binding": bindings["repository_binding"],
        "repository-generation": bindings["repository_generation"],
        "nested-team": "forbidden", "browser-profile": "forbidden",
    }
    if secondmate:
        tags.update({"agent-capacity": "one-home-scoped-secondmate", "child-launcher": "absent"})
    else:
        tags.update({
            "agent-capacity": "one-task-scoped-crewmate",
            "secondmate-placement": "forbidden",
        })
    serial = "{}-{}".format(action["cloud_generation"], action["idempotency_key"][:8])
    resources = {}
    for kind in (
        "vm", "nic", "os-disk", "task-disk", "account-disk", "identity",
        "role-assignment", "state-container", "monitor-extension",
        "bootstrap-command", "task-command", "ttl-schedule", "global-reservation",
        "staging-request", "staging-result",
    ):
        resources[kind] = {
            "id": "/fixture/slot/{}/{}".format(action["slot"], kind),
            "immutable_id": "{}-{}".format(kind, serial),
            "etag": "etag-{}".format(serial), "tags": dict(tags),
        }
    resources["vm"]["power_state"] = "VM running"
    for kind in ("nic", "os-disk", "task-disk", "account-disk", "monitor-extension",
                 "bootstrap-command", "task-command", "ttl-schedule"):
        resources[kind]["attached_to"] = resources["vm"]["id"]
    for kind in ("monitor-extension", "bootstrap-command", "task-command"):
        resources[kind]["provisioning_state"] = "Succeeded"
    resources["ttl-schedule"].update({"status": "Enabled", "deadline": "2300"})
    for kind in ("global-reservation", "staging-request", "staging-result"):
        resources[kind].update({"digest": "f" * 64, "length": 1})
    response["result"] = {
        "idempotency_key": action["idempotency_key"], "action": "create",
        "worker": {"slot": action["slot"], "resources": resources},
    }
else:
    response["result"] = {"status": "refused", "reason": "fixture provider performs no mutation"}
print(json.dumps(response, sort_keys=True, separators=(",", ":")))
PY
  chmod +x "$1"
}

# A fake `az` that can only record and fail. If any unit ever reaches the real
# Azure adapter, this is the tripwire.
write_forbidden_az() {
  mkdir -p "$1"
  cat >"$1/az" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$AZ_CALL_LOG"
echo "az is forbidden inside the placement suite" >&2
exit 1
SH
  chmod +x "$1/az"
}

# placement_world <var> <prefix> <profiles> - a hermetic controller home whose
# tasks all draw reusable snapshots from one Pi pool of <profiles> slots.
placement_world() {
  # The scratch variable is deliberately NOT named like the caller's: bash
  # locals are dynamically scoped, so a local named `world` here would shadow
  # the caller's `world` and printf -v would set this frame's copy instead.
  local target=$1 prefix=$2 profiles=$3 fm_placement_root
  fm_test_tmproot_into fm_placement_root "$prefix" || return 1
  mkdir -p "$fm_placement_root/home/state" "$fm_placement_root/home/data" \
    "$fm_placement_root/fakebin" "$fm_placement_root/fakepython"
  write_recording_provider "$fm_placement_root/provider.py"
  write_forbidden_az "$fm_placement_root/fakebin"
  cat > "$fm_placement_root/fakepython/sitecustomize.py" <<'PY'
import os
import pathlib
import tempfile
import time

original_mkstemp = tempfile.mkstemp


def synchronized_mkstemp(*args, **kwargs):
    handle, path = original_mkstemp(*args, **kwargs)
    marker = os.environ.get("FM_TEST_PROJECTION_BARRIER")
    if marker and "/azure-workers/accounts/" in path:
        pathlib.Path(marker).touch()
        while True:
            time.sleep(1)
    return handle, path


tempfile.mkstemp = synchronized_mkstemp
PY
  python3 - "$fm_placement_root/pool/auth.json" "$profiles" <<'PY' || return 1
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
path.parent.mkdir(parents=True, exist_ok=True)
pool = {}
for index in range(1, int(sys.argv[2]) + 1):
    name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
    pool[name] = {
        "type": "oauth", "access": "fixture-access-{}".format(index),
        "refresh": "fixture-refresh-{}".format(index),
        "accountId": "fixture-account-{}".format(index),
        "expires": 4102444800000,
    }
path.write_text(json.dumps(pool, sort_keys=True, indent=2), encoding="utf-8")
PY
  printf -v "$target" '%s' "$fm_placement_root"
}

# placement_task <world> <home> <task> <generation> - the ordinary local
# authorities a real request mints from, all pointed at the one pool.
placement_task() {
  local world=$1 home=$2 task=$3 generation=$4
  fm_git_init_commit "$world/wt-$task" >/dev/null || return 1
  python3 - "$home/state/$task.meta" "$generation" "$world/wt-$task" "$world/pool" "$task" <<'PY'
import os
import pathlib
import sys

meta, generation, worktree, pool, task = sys.argv[1:]
worktree = str(pathlib.Path(worktree).resolve())
git_dir = os.path.join(worktree, ".git")
stat = os.stat(git_dir)
pathlib.Path(meta).write_text(
    "generation_id={}\nworktree={}\naccount_home={}\naccount_task={}\n"
    "worktree_git_dir_identity={}:{}\n".format(
        generation, worktree, str(pathlib.Path(pool).resolve()), task,
        stat.st_dev, stat.st_ino),
    encoding="utf-8")
PY
}

run_placement() {  # <world> <args...>
  # The fixture provider is passed EXPLICITLY on every call, never inherited:
  # a run that fell back to the packaged Azure adapter would talk to a real
  # subscription. `az` is additionally shadowed by the recording tripwire.
  local world=$1
  shift
  env -u FM_AZURE_RESOURCE_GROUP -u FM_AZURE_STORAGE_NAME \
    FM_HOME="$world/home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $world/provider.py" \
    PROVIDER_CALL_LOG="$world/provider-calls.log" \
    CONTROLLER_PATH="$CONTROLLER" \
    AZ_CALL_LOG="$world/az-calls.log" \
    PYTHONPATH="$world/fakepython" \
    PATH="$world/fakebin:$PATH" \
    python3 "$CONTROLLER" "$@"
}

# Backgrounding a shell FUNCTION gives $! the subshell's pid, and a kill sent
# there leaves the controller running as its child - the kill would land on a
# process that was never doing the work. `exec` replaces the subshell, so $! is
# the controller itself.
run_placement_exec() {  # <world> <args...>
  local world=$1
  shift
  exec env -u FM_AZURE_RESOURCE_GROUP -u FM_AZURE_STORAGE_NAME \
    FM_HOME="$world/home" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $world/provider.py" \
    PROVIDER_CALL_LOG="$world/provider-calls.log" \
    CONTROLLER_PATH="$CONTROLLER" \
    AZ_CALL_LOG="$world/az-calls.log" \
    PYTHONPATH="$world/fakepython" \
    PATH="$world/fakebin:$PATH" \
    python3 "$CONTROLLER" "$@"
}

assert_no_cloud_call() {  # <world> <label>
  local world=$1 label=$2
  if [ -s "$world/az-calls.log" ]; then
    fail "$label reached the real Azure CLI: $(cat "$world/az-calls.log")"
  fi
  if [ ! -f "$world/provider.py" ]; then
    fail "$label ran without the fixture provider present"
  fi
}

placements() {  # <world> - "profile task" per line, sorted
  python3 - "$1/home/state/azure-workers/controller.json" <<'PY'
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
rows = [
    (item.get("account_profile"), item.get("task"))
    for item in state["queue"].values()
    if item.get("status") != "complete"
]
for profile, task in sorted(rows, key=lambda row: (row[0] or "", row[1] or "")):
    print("{} {}".format(profile, task))
PY
}

# --- units ------------------------------------------------------------------

sixteen_placements_reuse_fewer_profiles() {
  local world tasks=16 profiles=3 index status pids=()
  placement_world world fm-placement-concurrent "$profiles" || fail "world setup failed"
  for index in $(seq 1 "$tasks"); do
    placement_task "$world" "$world/home" "task-$index" "gen-$index" \
      || fail "task-$index authorities were not seeded"
  done
  # Started together and left to race the controller lock. A sequential loop
  # would prove nothing about exclusion.
  for index in $(seq 1 "$tasks"); do
    run_placement "$world" request --task "task-$index" \
      --task-generation "gen-$index" --owner-kind primary --eligible \
      > "$world/request-$index.out" 2> "$world/request-$index.err" &
    pids+=($!)
  done
  for index in "${!pids[@]}"; do
    wait "${pids[$index]}" || fail "concurrent request $((index + 1)) was refused: $(cat "$world/request-$((index + 1)).err")"
  done
  assert_no_cloud_call "$world" "the concurrent placement unit"
  echo "# concurrent placement result, read back from the durable controller document:"
  placements "$world" | sed 's/^/#   /'
  python3 - "$world/home/state/azure-workers/controller.json" "$world/home" "$tasks" "$profiles" <<'PY' \
    || fail "sixteen placements did not reuse fewer profiles safely"
import hashlib
import json
import pathlib
import sys

controller, home, expected, profile_count = (
    sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
)
state = json.load(open(controller, encoding="utf-8"))
items = [item for item in state["queue"].values() if item.get("status") != "complete"]
assert len(items) == expected, (len(items), expected)

profiles = [item["account_profile"] for item in items]
bindings = [item["account_binding"] for item in items]
homes = [item["account_home"] for item in items]
loads = {name: profiles.count(name) for name in set(profiles)}
assert len(loads) == profile_count, sorted(loads)
assert sorted(loads.values()) == [5, 5, 6], loads
assert len(set(bindings)) == profile_count, sorted(bindings)
assert len(set(homes)) == expected, sorted(homes)
assert len({item["account_projection_binding"] for item in items}) == expected

root = (home / "state" / "azure-workers" / "accounts").resolve()
seen_accounts = set()
for item in items:
    projected = pathlib.Path(item["account_home"])
    assert projected.parent.resolve() == root, projected
    assert projected.name == item["account_projection_binding"], item
    credential = json.load(open(projected / "auth.json", encoding="utf-8"))
    assert list(credential) == ["openai-codex"], (item["task"], sorted(credential))
    account = credential["openai-codex"]["accountId"]
    seen_accounts.add(account)
    assert item["account_binding"] == hashlib.sha256(json.dumps(
        {"provider": "pi", "upstream_account": hashlib.sha256(
            account.encode()).hexdigest()[:16]},
        sort_keys=True, separators=(",", ":")).encode()).hexdigest(), item
assert len(seen_accounts) == profile_count, sorted(seen_accounts)
PY
  status=$(run_placement "$world" status --json) || fail "sixteen-placement status failed"
  python3 - "$status" <<'PY' || fail "sixteen placements did not reach the independent worker ceiling"
import json
import sys
status = json.loads(sys.argv[1])
assert status["queue_depth"] == 16, status
assert status["desired_active_workers"] == 16, status
assert sorted(row["active_placements"] for row in status["account_profile_loads"]) == [5, 5, 6], status
assert len(status["account_placements"]) == 16, status
PY
  run_placement "$world" capacity-reserve \
    --reservation-id azr-validation001 --fence-binding "$(printf 'a%.0s' {1..64})" \
    --role validation --sku Standard_D4as_v7 --sku-family StandardDasv7Family \
    --vcpus 4 --amount-usd 1 --confirm-subscription "$SUB" > /dev/null \
    || fail "no-mistakes specialized capacity was counted as a worker slot"
  run_placement "$world" capacity-reserve \
    --reservation-id azr-crosscheck001 --fence-binding "$(printf 'b%.0s' {1..64})" \
    --role crosscheck --sku Standard_D4s_v6 --sku-family StandardDsv6Family \
    --vcpus 4 --amount-usd 1 --confirm-subscription "$SUB" > /dev/null \
    || fail "Crosscheck specialized capacity consumed a worker profile or slot"
  status=$(run_placement "$world" status --json) || fail "combined capacity status failed"
  python3 - "$status" "$world/home/state/azure-workers/controller.json" <<'PY' \
    || fail "specialized lanes changed worker/profile admission"
import json
import sys
status = json.loads(sys.argv[1])
state = json.load(open(sys.argv[2], encoding="utf-8"))
assert status["queue_depth"] == 16 and status["desired_active_workers"] == 16, status
assert status["specialized_reserved_reservations"] == 2, status
assert status["specialized_reserved_vcpus"] == 8, status
assert {row["role"] for row in state["capacity_reservations"].values()} == {"specialized"}, state
assert {row["workload_role"] for row in state["capacity_reservations"].values()} == {
    "validation", "crosscheck",
}, state
assert len(status["account_placements"]) == 16, status
PY
  pass "sixteen workers reuse three profiles while no-mistakes and Crosscheck reserve specialized capacity independently"
}

placements_reuse_after_every_profile_is_active() {
  local world index
  placement_world world fm-placement-reuse 2 || fail "world setup failed"
  for index in 1 2 3 4; do
    placement_task "$world" "$world/home" "task-$index" "gen-$index" \
      || fail "task-$index authorities were not seeded"
    run_placement "$world" request --task "task-$index" \
      --task-generation "gen-$index" --owner-kind primary --eligible \
      > /dev/null 2> "$world/err-$index" \
      || fail "placement $index was refused: $(cat "$world/err-$index")"
  done
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY' \
    || fail "placements beyond the profile count were not balanced"
import collections
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
items = [item for item in state["queue"].values() if item["status"] != "complete"]
assert len(items) == 4, items
assert collections.Counter(item["account_profile"] for item in items) == {
    "openai-codex": 2, "openai-codex-2": 2,
}, items
assert len({item["account_home"] for item in items}) == 4, items
PY
  assert_no_cloud_call "$world" "the profile-reuse unit"
  pass "placements beyond the profile count reuse the least-loaded profile with stable tie-breaking"
}

withdraw_cleans_only_its_private_projection() {
  local world index first_home second_home canonical_before canonical_after
  placement_world world fm-placement-cleanup 1 || fail "world setup failed"
  for index in 1 2; do
    placement_task "$world" "$world/home" "task-$index" "gen-$index" \
      || fail "task-$index authorities were not seeded"
    run_placement "$world" request --task "task-$index" \
      --task-generation "gen-$index" --owner-kind primary --eligible \
      > /dev/null 2>&1 || fail "placement $index was refused"
  done
  first_home=$(python3 - "$world/home/state/azure-workers/controller.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
print(state["queue"]["task-1@gen-1"]["account_home"])
PY
)
  second_home=$(python3 - "$world/home/state/azure-workers/controller.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
print(state["queue"]["task-2@gen-2"]["account_home"])
PY
)
  [ "$first_home" != "$second_home" ] || fail "same-profile placements shared a writable projection"
  canonical_before=$(shasum -a 256 "$world/pool/auth.json" | awk '{print $1}')
  run_placement "$world" withdraw --task task-1 --task-generation gen-1 \
    --confirm-withdraw --confirm-subscription "$SUB" > /dev/null 2>"$world/withdraw.err" \
    || fail "withdrawing a queued placement failed: $(cat "$world/withdraw.err")"
  canonical_after=$(shasum -a 256 "$world/pool/auth.json" | awk '{print $1}')
  [ ! -e "$first_home" ] || fail "withdraw left its assignment-private projection behind"
  [ -f "$second_home/auth.json" ] || fail "withdraw deleted another same-profile projection"
  [ "$canonical_before" = "$canonical_after" ] || fail "withdraw changed the canonical host profile"
  assert_no_cloud_call "$world" "the assignment cleanup unit"
  pass "cleanup removes one private projection without inspecting or deleting its same-profile peer"
}

interrupted_snapshot_remains_owned_and_resumable() {
  local world victim observed=0 index crashed_home replay_out replay_home
  placement_world world fm-placement-crash 3 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "task-1 authorities were not seeded"
  placement_task "$world" "$world/home" task-2 gen-2 || fail "task-2 authorities were not seeded"
  # The fixture barrier stops at the real atomic-write boundary. Observing its
  # marker proves the request selected an account and entered projection,
  # without guessing at scheduler timing.
  FM_TEST_PROJECTION_BARRIER="$world/projection-entered" \
    run_placement_exec "$world" request --task task-1 \
    --task-generation gen-1 --owner-kind primary --eligible > /dev/null 2>&1 &
  victim=$!
  for index in $(seq 1 5000); do
    if [ -e "$world/projection-entered" ]; then
      observed=1
      break
    fi
    kill -0 "$victim" 2>/dev/null || break
    sleep 0.001
  done
  [ "$observed" -eq 1 ] || {
    kill -9 "$victim" 2>/dev/null || true
    wait "$victim" 2>/dev/null || true
    fail "the placement never exposed its atomic credential-write boundary"
  }
  kill -9 "$victim" 2>/dev/null || fail "the placement escaped before the synchronized kill"
  wait "$victim" 2>/dev/null || true
  crashed_home=$(python3 - "$world/home/state/azure-workers/controller.json" <<'PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
item = state["queue"]["task-1@gen-1"]
assert item["status"] == "projecting", item
print(item["account_home"])
PY
) || fail "the interrupted projection has no durable owner"
  replay_out=$(run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible 2>&1) \
    || fail "the interrupted projection did not resume: $replay_out"
  replay_home=$(printf '%s\n' "$replay_out" | awk '$1 == "account-home" { print $2; exit }')
  [ "$crashed_home" = "$replay_home" ] \
    || fail "projection replay changed path: before=$crashed_home after=$replay_home"
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>"$world/survivor.err" \
    || fail "the uninterrupted placement was refused: $(cat "$world/survivor.err")"
  python3 - "$world/home/state/azure-workers/controller.json" "$world/home" <<'PY' \
    || fail "a killed snapshot write lost its durable cleanup owner"
import json
import pathlib
import sys

controller = pathlib.Path(sys.argv[1])
home = pathlib.Path(sys.argv[2])
state = json.loads(controller.read_text(encoding="utf-8"))
items = {item["task"]: item for item in state["queue"].values()
         if item.get("status") != "complete"}
assert set(items) == {"task-1", "task-2"}, items
assert items["task-1"]["status"] == "queued", items
assert items["task-2"]["status"] == "queued", items
root = home / "state" / "azure-workers" / "accounts"
projected = {path.name for path in root.iterdir()} if root.is_dir() else set()
owned = {item["account_projection_binding"] for item in items.values()}
assert projected == owned, (projected, owned)
assert len({item["account_home"] for item in items.values()}) == 2, items
print("# survived-the-kill projections: {}".format(
    ", ".join("{}={}".format(item["status"], item["account_projection_binding"])
              for item in items.values())))
PY
  # Recovery: withdraw every survivor and prove the whole pool is free again.
  python3 - "$world/home/state/azure-workers/controller.json" > "$world/survivors" <<'PY'
import json
import pathlib
import sys

controller = pathlib.Path(sys.argv[1])
state = json.loads(controller.read_text(encoding="utf-8")) if controller.exists() else {"queue": {}}
for key, item in sorted(state.get("queue", {}).items()):
    if item.get("status") != "complete":
        print("{} {}".format(item["task"], item["task_generation"]))
PY
  while read -r task generation; do
    [ -n "$task" ] || continue
    run_placement "$world" withdraw --task "$task" --task-generation "$generation" \
      --confirm-withdraw --confirm-subscription "$SUB" > /dev/null 2>&1 \
      || fail "a crashed placement's private projection could not be recovered by withdraw"
  done < "$world/survivors"
  placement_task "$world" "$world/home" recovered rgen || fail "recovery task not seeded"
  run_placement "$world" request --task recovered --task-generation rgen \
    --owner-kind primary --eligible > /dev/null 2>"$world/recovered.err" \
    || fail "the pool did not recover after every crashed projection was withdrawn: $(cat "$world/recovered.err")"
  assert_contains "$(placements "$world")" "openai-codex recovered" \
    "recovery did not return the first account to the pool: $(placements "$world")"
  assert_no_cloud_call "$world" "the crash-safety unit"
  pass "a killed snapshot write remains queue-owned, resumable, and exactly removable"
}

compartments_and_crewmates_share_balanced_worker_profiles() {
  local world compartment out
  placement_world world fm-placement-compartment 4 || fail "world setup failed"
  compartment="$world/compartment"
  mkdir -p "$compartment/state" "$compartment/bin"
  printf 'fixture home\n' > "$compartment/AGENTS.md"
  printf 'smc-1\n' > "$compartment/.fm-secondmate-home"
  printf '# secondmates\n- smc-1 - a compartment (home: %s; scope: everything; projects: ; added 2026-08-20)\n' \
    "$compartment" > "$world/home/data/secondmates.md"
  placement_task "$world" "$world/home" smc-1 gen-s1 || fail "compartment authorities not seeded"
  placement_task "$world" "$compartment" child-1 gen-c1 || fail "child authorities not seeded"
  placement_task "$world" "$world/home" crew-1 gen-w1 || fail "crewmate authorities not seeded"
  run_placement "$world" request --task smc-1 --task-generation gen-s1 \
    --owner-kind primary --role secondmate --eligible > /dev/null 2>"$world/smc.err" \
    || fail "the compartment placement was refused: $(cat "$world/smc.err")"
  run_placement "$world" reconcile --apply --confirm-subscription "$SUB" --json \
    > /dev/null 2>"$world/reconcile.err" \
    || fail "the compartment reconcile was refused: $(cat "$world/reconcile.err")"
  [ -s "$world/provider-calls.log" ] \
    || fail "the reconcile never reached the fixture provider, so the lane is unproven"
  # The compartment child and an ordinary crewmate placed CONCURRENTLY: both
  # draw from the one controller document, so neither can see a stale free set.
  run_placement "$world" request --task child-1 --task-generation gen-c1 \
    --owner-kind secondmate --role author --task-home "$compartment" \
    --parent-task smc-1 --parent-task-generation gen-s1 --eligible \
    > /dev/null 2> "$world/child.err" &
  local child_pid=$!
  run_placement "$world" request --task crew-1 --task-generation gen-w1 \
    --owner-kind primary --eligible > /dev/null 2> "$world/crew.err" &
  local crew_pid=$!
  wait "$child_pid" || fail "the compartment child placement was refused: $(cat "$world/child.err")"
  wait "$crew_pid" || fail "the crewmate placement was refused: $(cat "$world/crew.err")"
  echo "# compartment, child and crewmate placements:"
  placements "$world" | sed 's/^/#   /'
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY' \
    || fail "a compartment child and a crewmate shared an upstream account"
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
items = {item["task"]: item for item in state["queue"].values()
         if item.get("status") != "complete"}
assert set(items) == {"smc-1", "child-1", "crew-1"}, sorted(items)
bindings = {task: item["account_binding"] for task, item in items.items()}
assert len(set(bindings.values())) == 3, bindings
profiles = {task: item["account_profile"] for task, item in items.items()}
assert len(set(profiles.values())) == 3, profiles
# The child's lease came out of the PRIMARY's document, which is what makes it
# exclusive against a crewmate the primary placed at the same moment.
assert items["child-1"]["parent_task"] == "smc-1", items["child-1"]
PY
  assert_no_cloud_call "$world" "the compartment unit"
  pass "a compartment child, its parent, and an ordinary crewmate share the same load-balanced worker pool"
}

replay_reuses_its_exact_profile_and_projection() {
  local world out first_home replay_home
  placement_world world fm-placement-replay 4 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > "$world/first.out" 2>&1 \
    || fail "the first placement was refused: $(cat "$world/first.out")"
  out=$(run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible 2>&1) \
    || fail "the replayed placement was refused: $out"
  assert_contains "$out" "request already exists with exact identity" \
    "a replayed placement was not recognised as the same request: $out"
  assert_contains "$out" "account-home" \
    "a replayed placement did not report the account home it already holds: $out"
  first_home=$(awk '$1 == "account-home" { print $2; exit }' "$world/first.out")
  replay_home=$(printf '%s\n' "$out" | awk '$1 == "account-home" { print $2; exit }')
  [ -n "$first_home" ] && [ "$first_home" = "$replay_home" ] \
    || fail "replay changed its assignment-private projection: first=$first_home replay=$replay_home"
  # A DIFFERENT generation is a different placement and takes the next
  # least-loaded profile plus another private projection.
  placement_task "$world" "$world/home" task-1b gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1b --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 \
    || fail "the second placement was refused"
  assert_contains "$(placements "$world")" "openai-codex task-1" \
    "the replayed placement moved off its account: $(placements "$world")"
  assert_contains "$(placements "$world")" "openai-codex-2 task-1b" \
    "a second placement did not take the next free account: $(placements "$world")"
  assert_no_cloud_call "$world" "the replay unit"
  pass "replay preserves its profile and private projection while a new generation takes the next least-loaded profile"
}

two_profiles_on_one_account_remain_reusable() {
  local world
  placement_world world fm-placement-shared-account 2 || fail "world setup failed"
  # The 1:1 profile-to-account mapping is not an invariant.  Two local slots
  # may identify one upstream account; the digest remains equal and visible,
  # while each assignment still receives a distinct writable projection.
  python3 - "$world/pool/auth.json" <<'PY' || fail "shared-account pool not written"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pool = json.loads(path.read_text(encoding="utf-8"))
for entry in pool.values():
    entry["accountId"] = "one-shared-account"
path.write_text(json.dumps(pool, sort_keys=True, indent=2), encoding="utf-8")
PY
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  placement_task "$world" "$world/home" task-2 gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 \
    || fail "the first placement was refused"
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 \
    || fail "the second same-account placement was refused"
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY' \
    || fail "same-account profiles did not retain private assignment custody"
import json
import sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
one = state["queue"]["task-1@gen-1"]
two = state["queue"]["task-2@gen-2"]
assert one["account_binding"] == two["account_binding"], (one, two)
assert one["account_profile"] != two["account_profile"], (one, two)
assert one["account_home"] != two["account_home"], (one, two)
assert one["account_projection_binding"] != two["account_projection_binding"], (one, two)
PY
  assert_no_cloud_call "$world" "the shared-account unit"
  pass "one upstream account binding may back multiple isolated assignment snapshots"
}

status_shows_who_holds_which_account() {
  local world out
  placement_world world fm-placement-status 1 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  placement_task "$world" "$world/home" task-2 gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "placement refused"
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "reused placement refused"
  out=$(run_placement "$world" status 2>&1) || fail "status failed: $out"
  assert_contains "$out" "account-profile-load: profile=openai-codex active=2 account-binding=" \
    "status does not report reusable profile load: $out"
  assert_contains "$out" "account-placement: profile=openai-codex load=2 task=task-1@gen-1" \
    "status does not report each placement under shared load: $out"
  assert_contains "$out" "account-placement: profile=openai-codex load=2 task=task-2@gen-2" \
    "status collapsed two same-profile placements: $out"
  out=$(run_placement "$world" status --json 2>&1) || fail "json status failed: $out"
  python3 - "$out" <<'PY' || fail "machine-readable multi-placement status is inaccurate"
import json, sys
status = json.loads(sys.argv[1])
assert len(status["account_placements"]) == 2, status
assert status["account_profile_loads"][0]["active_placements"] == 2, status
assert {row["profile_active_load"] for row in status["account_placements"]} == {2}, status
assert all(row["account_binding"] for row in status["account_placements"]), status
assert len({row["account_home"] for row in status["account_placements"]}) == 2, status
PY
  assert_no_cloud_call "$world" "the status unit"
  pass "status names the account each live placement holds, in both renderings"
}

host_refresh_never_rewrites_a_live_snapshot() {
  local world
  placement_world world fm-placement-relogin 1 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  placement_task "$world" "$world/home" task-2 gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "the first placement was refused"
  # Simulate a host-side refresh/re-login after the first immutable snapshot.
  # The next placement snapshots the new canonical bytes, while the first
  # assignment keeps its exact old bytes and private path.
  python3 - "$world/pool/auth.json" <<'PY2' || fail "re-login rewrite failed"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
pool = json.loads(path.read_text(encoding="utf-8"))
pool["openai-codex"]["accountId"] = "fixture-account-relogged"
path.write_text(json.dumps(pool, sort_keys=True, indent=2), encoding="utf-8")
PY2
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "the second placement was refused"
  echo "# placements after a re-login of slot openai-codex:"
  placements "$world" | sed 's/^/#   /'
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY2' \
    || fail "a re-logged slot clobbered a live placement's credential"
import json
import pathlib
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
items = {item["task"]: item for item in state["queue"].values()
         if item.get("status") != "complete"}
assert set(items) == {"task-1", "task-2"}, sorted(items)
one, two = items["task-1"], items["task-2"]
assert one["account_binding"] != two["account_binding"], (one, two)
# The two snapshots bind two observed account identities and private homes.
assert one["account_home"] != two["account_home"], (one["account_home"], two["account_home"])
# The first snapshot remains immutable when the host updates the canonical
# profile, and the later assignment receives the refreshed canonical identity.
first = json.load(open(pathlib.Path(one["account_home"]) / "auth.json", encoding="utf-8"))
second = json.load(open(pathlib.Path(two["account_home"]) / "auth.json", encoding="utf-8"))
assert list(first) == ["openai-codex"] and list(second) == ["openai-codex"], (first, second)
assert first["openai-codex"]["accountId"] == "fixture-account-1", first["openai-codex"]["accountId"]
assert second["openai-codex"]["accountId"] == "fixture-account-relogged", \
    second["openai-codex"]["accountId"]
PY2
  assert_no_cloud_call "$world" "the re-login unit"
  pass "host refresh changes only later snapshots and never rewrites a live assignment projection"
}

two_pools_with_the_same_slot_names_stay_two_placements() {
  local world
  placement_world world fm-placement-twopools 2 || fail "world setup failed"
  # Two pool PATHS carrying the same slot names and different accounts. Keyed
  # on the slot name both would land in one directory; keyed on the lease they
  # cannot.
  mkdir -p "$world/pool-b" || fail "second pool not created"
  python3 - "$world/pool/auth.json" "$world/pool-b/auth.json" <<'PY2' || fail "second pool not written"
import json
import pathlib
import sys

pool = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for index, name in enumerate(sorted(pool), start=1):
    pool[name]["accountId"] = "other-pool-account-{}".format(index)
pathlib.Path(sys.argv[2]).write_text(json.dumps(pool, sort_keys=True, indent=2), encoding="utf-8")
PY2
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  fm_git_init_commit "$world/wt-task-2" > /dev/null || fail "worktree not created"
  python3 - "$world/home/state/task-2.meta" "$world/wt-task-2" "$world/pool-b" <<'PY2' || fail "meta not written"
import os
import pathlib
import sys

meta, worktree, pool = sys.argv[1:]
worktree = str(pathlib.Path(worktree).resolve())
git_dir = os.path.join(worktree, ".git")
stat = os.stat(git_dir)
pathlib.Path(meta).write_text(
    "generation_id=gen-2\nworktree={}\naccount_home={}\naccount_task=task-2\n"
    "worktree_git_dir_identity={}:{}\n".format(
        worktree, str(pathlib.Path(pool).resolve()), stat.st_dev, stat.st_ino),
    encoding="utf-8")
PY2
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "the first placement was refused"
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "the second placement was refused"
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY2' \
    || fail "two pools sharing slot names collapsed onto one account home"
import json
import pathlib
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
items = {item["task"]: item for item in state["queue"].values()
         if item.get("status") != "complete"}
one, two = items["task-1"], items["task-2"]
assert one["account_home"] != two["account_home"], one["account_home"]
first = json.load(open(pathlib.Path(one["account_home"]) / "auth.json", encoding="utf-8"))
second = json.load(open(pathlib.Path(two["account_home"]) / "auth.json", encoding="utf-8"))
assert first["openai-codex"]["accountId"] != second["openai-codex"]["accountId"], first
PY2
  assert_no_cloud_call "$world" "the two-pool unit"
  pass "two pools carrying the same slot names resolve to two account homes, not one"
}

headroom_refuses_before_snapshot() {
  local world out status canonical_before canonical_after
  placement_world world fm-placement-headroom 1 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  python3 - "$world/pool/auth.json" <<'PY' || fail "near-expiry profile not written"
import json
import pathlib
import sys
import time
path = pathlib.Path(sys.argv[1])
pool = json.loads(path.read_text(encoding="utf-8"))
pool["openai-codex"]["expires"] = int((time.time() + 11 * 60 * 60) * 1000)
path.write_text(json.dumps(pool, sort_keys=True, indent=2), encoding="utf-8")
PY
  canonical_before=$(shasum -a 256 "$world/pool/auth.json" | awk '{print $1}')
  out=$(run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a profile below twelve-hour headroom produced a snapshot: $out"
  assert_contains "$out" "lacks twelve hours of access-token headroom" \
    "the pre-snapshot headroom refusal was not explicit: $out"
  canonical_after=$(shasum -a 256 "$world/pool/auth.json" | awk '{print $1}')
  [ "$canonical_before" = "$canonical_after" ] || fail "headroom preflight mutated the host profile"
  if [ -d "$world/home/state/azure-workers/accounts" ] \
    && find "$world/home/state/azure-workers/accounts" -mindepth 1 -print -quit | grep -q .; then
    fail "headroom refusal wrote an assignment snapshot before checking expiry"
  fi
  [ ! -e "$world/home/state/azure-workers/controller.json" ] \
    || python3 - "$world/home/state/azure-workers/controller.json" <<'PY' \
      || fail "headroom refusal still inserted a queue entry"
import json, sys
assert not json.load(open(sys.argv[1], encoding="utf-8"))["queue"]
PY
  assert_no_cloud_call "$world" "the headroom unit"
  pass "twelve-hour headroom is proved on the host before any assignment snapshot is written"
}

sixteen_placements_reuse_fewer_profiles
placements_reuse_after_every_profile_is_active
headroom_refuses_before_snapshot
withdraw_cleans_only_its_private_projection
interrupted_snapshot_remains_owned_and_resumable
compartments_and_crewmates_share_balanced_worker_profiles
replay_reuses_its_exact_profile_and_projection
two_profiles_on_one_account_remain_reusable
status_shows_who_holds_which_account
host_refresh_never_rewrites_a_live_snapshot
two_pools_with_the_same_slot_names_stay_two_placements
echo "# fm-worker-placement.test.sh: all assertions passed"
