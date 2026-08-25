#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior: multi-profile provider-account placement for crewmate and worker
# requests (R5). Concurrent placements land on DISTINCT upstream accounts, an
# exhausted pool refuses by name instead of sharing one, a crashed placement
# leaves a lease the queue still shows, and a compartment child contends for the
# same pool as an ordinary crewmate.
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
# tasks all draw from one Pi pool of <profiles> distinct upstream accounts.
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

concurrent_placements_take_distinct_accounts() {
  local world tasks=8 index pids=()
  placement_world world fm-placement-concurrent "$tasks" || fail "world setup failed"
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
  python3 - "$world/home/state/azure-workers/controller.json" "$world/home" "$tasks" <<'PY' \
    || fail "concurrent placements did not take distinct upstream accounts"
import hashlib
import json
import pathlib
import sys

controller, home, expected = sys.argv[1], pathlib.Path(sys.argv[2]), int(sys.argv[3])
state = json.load(open(controller, encoding="utf-8"))
items = [item for item in state["queue"].values() if item.get("status") != "complete"]
assert len(items) == expected, (len(items), expected)

profiles = [item["account_profile"] for item in items]
bindings = [item["account_binding"] for item in items]
homes = [item["account_home"] for item in items]
assert len(set(profiles)) == expected, sorted(profiles)
assert len(set(bindings)) == expected, sorted(bindings)
assert len(set(homes)) == expected, sorted(homes)

root = (home / "state" / "azure-workers" / "accounts").resolve()
seen_accounts = set()
for item in items:
    leased = pathlib.Path(item["account_home"])
    # Hermeticity: every projected home is under THIS controller's own state
    # directory, never a shared machine-wide roster.
    assert root in leased.resolve().parents or leased.resolve() == root, leased
    credential = json.load(open(leased / "auth.json", encoding="utf-8"))
    # The staged credential is single-profile. A pooled one would put every
    # signed-in account on the worker and let the guest pick the first slot.
    assert list(credential) == ["openai-codex"], (item["task"], sorted(credential))
    account = credential["openai-codex"]["accountId"]
    assert account not in seen_accounts, ("two placements share an upstream account", account)
    seen_accounts.add(account)
    # The lease identity is the upstream account and nothing else.
    assert item["account_binding"] == hashlib.sha256(json.dumps(
        {"provider": "pi", "upstream_account": hashlib.sha256(
            account.encode()).hexdigest()[:16]},
        sort_keys=True, separators=(",", ":")).encode()).hexdigest(), item
assert len(seen_accounts) == expected, sorted(seen_accounts)
PY
  pass "concurrent placements race the controller lock and land on distinct upstream accounts"
}

exhaustion_refuses_by_name() {
  local world index status out
  placement_world world fm-placement-exhaustion 3 || fail "world setup failed"
  for index in 1 2 3 4; do
    placement_task "$world" "$world/home" "task-$index" "gen-$index" \
      || fail "task-$index authorities were not seeded"
  done
  for index in 1 2 3; do
    run_placement "$world" request --task "task-$index" \
      --task-generation "gen-$index" --owner-kind primary --eligible \
      > /dev/null 2> "$world/err-$index" \
      || fail "placement $index was refused: $(cat "$world/err-$index")"
  done
  out=$(run_placement "$world" request --task task-4 --task-generation gen-4 \
    --owner-kind primary --eligible 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a placement with no free account was admitted: $out"
  echo "# exhaustion refusal, verbatim:"
  printf '%s\n' "$out" | sed 's/^/#   /'
  assert_contains "$out" "provider-account placement is exhausted" \
    "the exhaustion refusal does not name itself: $out"
  assert_contains "$out" "refusing to place task-4 on a shared upstream account" \
    "the exhaustion refusal does not name the placement it refused: $out"
  for index in 1 2 3; do
    assert_contains "$out" "task-$index" \
      "the exhaustion refusal does not name the task holding each account: $out"
  done
  assert_contains "$out" "openai-codex" \
    "the exhaustion refusal does not name the leased profiles: $out"
  python3 - "$world/home/state/azure-workers/controller.json" <<'PY' \
    || fail "the refused placement still mutated the queue"
import json
import sys

state = json.load(open(sys.argv[1], encoding="utf-8"))
assert "task-4@gen-4" not in state["queue"], sorted(state["queue"])
assert len(state["queue"]) == 3, sorted(state["queue"])
PY
  assert_no_cloud_call "$world" "the exhaustion unit"
  pass "an exhausted account pool refuses the next placement by name instead of sharing an account"
}

a_withdrawn_placement_returns_its_account() {
  local world index out status
  placement_world world fm-placement-return 2 || fail "world setup failed"
  for index in 1 2 3; do
    placement_task "$world" "$world/home" "task-$index" "gen-$index" \
      || fail "task-$index authorities were not seeded"
  done
  for index in 1 2; do
    run_placement "$world" request --task "task-$index" \
      --task-generation "gen-$index" --owner-kind primary --eligible \
      > /dev/null 2>&1 || fail "placement $index was refused"
  done
  out=$(run_placement "$world" request --task task-3 --task-generation gen-3 \
    --owner-kind primary --eligible 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "a third placement was admitted into a two-account pool: $out"
  run_placement "$world" withdraw --task task-1 --task-generation gen-1 \
    --confirm-withdraw --confirm-subscription "$SUB" > /dev/null 2>"$world/withdraw.err" \
    || fail "withdrawing a queued placement failed: $(cat "$world/withdraw.err")"
  run_placement "$world" request --task task-3 --task-generation gen-3 \
    --owner-kind primary --eligible > /dev/null 2>"$world/retry.err" \
    || fail "the freed account was not available to the next placement: $(cat "$world/retry.err")"
  assert_contains "$(placements "$world")" "openai-codex task-3" \
    "the freed profile did not return to the pool: $(placements "$world")"
  assert_no_cloud_call "$world" "the account-return unit"
  pass "a released account returns to the pool and the next placement takes exactly it"
}

a_killed_placement_never_orphans_an_account() {
  local world victim observed=0 index
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
  run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>"$world/survivor.err" \
    || fail "the uninterrupted placement was refused: $(cat "$world/survivor.err")"
  python3 - "$world/home/state/azure-workers/controller.json" "$world/home" <<'PY' \
    || fail "a killed placement orphaned an account"
import json
import pathlib
import sys

controller = pathlib.Path(sys.argv[1])
home = pathlib.Path(sys.argv[2])
state = json.loads(controller.read_text(encoding="utf-8")) if controller.exists() else {"queue": {}}
items = [item for item in state.get("queue", {}).values() if item.get("status") != "complete"]
held = [item["account_profile"] for item in items]
assert [item["task"] for item in items] == ["task-2"], items
# The lease IS the queue entry: every account that is held is held BY a visible
# entry, so a kill can leave work queued but can never leave an account held by
# nothing. Duplicates would mean two entries share an account.
assert len(held) == len(set(held)), sorted(held)
print("# survived-the-kill placements: {}".format(
    ", ".join("{}={}".format(item["account_profile"], item["task"])
              for item in sorted(items, key=lambda entry: entry["account_profile"]))
    or "none"))
# Every projected account home that exists on disk is either free or named by an
# entry; a home with no entry is inert, not a lease, so the pool is intact.
root = home / "state" / "azure-workers" / "accounts"
projected = sorted(path.name for path in root.iterdir()) if root.is_dir() else []
print("# projected account homes: {}".format(", ".join(projected) or "none"))
orphaned = sorted(set(projected) - set(held))
# A projected home that no queue entry names is inert, not a lease: it holds
# nothing and the next placement may take it. Reported, not refused, because
# the question this unit answers is whether an ACCOUNT can be held by nothing.
print("# projected but unleased (free for the next placement): {}".format(
    ", ".join(orphaned) or "none"))
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
      || fail "a crashed placement's account could not be recovered by withdraw"
  done < "$world/survivors"
  placement_task "$world" "$world/home" recovered rgen || fail "recovery task not seeded"
  run_placement "$world" request --task recovered --task-generation rgen \
    --owner-kind primary --eligible > /dev/null 2>"$world/recovered.err" \
    || fail "the pool did not recover after every crashed lease was withdrawn: $(cat "$world/recovered.err")"
  assert_contains "$(placements "$world")" "openai-codex recovered" \
    "recovery did not return the first account to the pool: $(placements "$world")"
  assert_no_cloud_call "$world" "the crash-safety unit"
  pass "a placement killed between account selection and its durable lease orphans no account, and withdraw recovers every survivor"
}

a_compartment_child_contends_with_a_crewmate() {
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
  pass "a compartment child, its compartment, and an ordinary crewmate hold three distinct upstream accounts"
}

replay_reuses_its_account_and_a_new_generation_takes_another() {
  local world out
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
  # A DIFFERENT generation is a different placement and takes its own account.
  placement_task "$world" "$world/home" task-1b gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1b --task-generation gen-2 \
    --owner-kind primary --eligible > /dev/null 2>&1 \
    || fail "the second placement was refused"
  assert_contains "$(placements "$world")" "openai-codex task-1" \
    "the replayed placement moved off its account: $(placements "$world")"
  assert_contains "$(placements "$world")" "openai-codex-2 task-1b" \
    "a second placement did not take the next free account: $(placements "$world")"
  assert_no_cloud_call "$world" "the replay unit"
  pass "replaying one placement reuses its account, and a new generation takes the next free one"
}

two_profiles_on_one_account_are_one_lease() {
  local world out status
  placement_world world fm-placement-shared-account 2 || fail "world setup failed"
  # The 1:1 profile-to-account mapping is a fact of today's fleet, not an
  # invariant. Point both profiles at ONE upstream account and the pool must
  # collapse to one lease, because the account is what a placement contends for.
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
  out=$(run_placement "$world" request --task task-2 --task-generation gen-2 \
    --owner-kind primary --eligible 2>&1) && status=0 || status=$?
  expect_code 2 "$status" "two profiles sharing one upstream account admitted two placements: $out"
  assert_contains "$out" "provider-account placement is exhausted" \
    "the shared-account refusal is not the exhaustion refusal: $out"
  assert_no_cloud_call "$world" "the shared-account unit"
  pass "two profiles resolving to one upstream account are one lease, not two"
}

status_shows_who_holds_which_account() {
  local world out
  placement_world world fm-placement-status 3 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "placement refused"
  out=$(run_placement "$world" status 2>&1) || fail "status failed: $out"
  assert_contains "$out" "account-placement: profile=openai-codex task=task-1@gen-1" \
    "status does not report who holds which account: $out"
  out=$(run_placement "$world" status --json 2>&1) || fail "json status failed: $out"
  assert_contains "$out" '"account_placements"' \
    "the machine-readable status omits the account placements: $out"
  assert_no_cloud_call "$world" "the status unit"
  pass "status names the account each live placement holds, in both renderings"
}

a_relogged_slot_never_clobbers_a_live_placements_credential() {
  local world
  placement_world world fm-placement-relogin 2 || fail "world setup failed"
  placement_task "$world" "$world/home" task-1 gen-1 || fail "authorities not seeded"
  placement_task "$world" "$world/home" task-2 gen-2 || fail "authorities not seeded"
  run_placement "$world" request --task task-1 --task-generation gen-1 \
    --owner-kind primary --eligible > /dev/null 2>&1 || fail "the first placement was refused"
  # The exact case the exclusion unit is chosen for: an operator re-logs the
  # SAME slot name into a DIFFERENT upstream account. Both placements are
  # correct and distinct leases. If the projected home were keyed on the slot
  # name the second projection would overwrite the credential the first
  # placement's still-live lease points at.
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
# The two leases are two accounts, so they must be two directories.
assert one["account_home"] != two["account_home"], (one["account_home"], two["account_home"])
# And the FIRST placement's credential must still be the account it leased,
# read off the disk rather than off the queue.
first = json.load(open(pathlib.Path(one["account_home"]) / "auth.json", encoding="utf-8"))
second = json.load(open(pathlib.Path(two["account_home"]) / "auth.json", encoding="utf-8"))
assert list(first) == ["openai-codex"] and list(second) == ["openai-codex"], (first, second)
assert first["openai-codex"]["accountId"] == "fixture-account-1", first["openai-codex"]["accountId"]
assert second["openai-codex"]["accountId"] == "fixture-account-relogged", \
    second["openai-codex"]["accountId"]
PY2
  assert_no_cloud_call "$world" "the re-login unit"
  pass "re-logging one slot into another account never overwrites the credential a live placement leased"
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

concurrent_placements_take_distinct_accounts
exhaustion_refuses_by_name
a_withdrawn_placement_returns_its_account
a_killed_placement_never_orphans_an_account
a_compartment_child_contends_with_a_crewmate
replay_reuses_its_account_and_a_new_generation_takes_another
two_profiles_on_one_account_are_one_lease
status_shows_who_holds_which_account
a_relogged_slot_never_clobbers_a_live_placements_credential
two_pools_with_the_same_slot_names_stay_two_placements
echo "# fm-worker-placement.test.sh: all assertions passed"
