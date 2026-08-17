#!/usr/bin/env bash
# shellcheck source=tests/test-entry.sh
. "$(dirname "$0")/test-entry.sh"
# Behavior tests for fm-spawn.sh cloud placement (FM_SPAWN_CLOUD / the
# config/spawn-cloud file): the default-off lane must stay byte-identical to
# the local path, and the azure lane must persist the lifecycle bindings
# (placement, account_home, worktree_git_dir_identity), skip the local
# endpoint, and drive bin/fm-worker-lifecycle.sh request/reconcile/execute
# against a hermetic fixture provider. No Azure CLI or network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-cloud)
SUB=11111111-1111-4111-8111-111111111111

# --- fixtures ---------------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  # The herdr adapter's safe-ancestry check refuses any group-writable
  # non-root directory or binary on the resolved path (a umask 002 host
  # would otherwise create 775 fixtures and unpin the fake).
  chmod 755 "$dir" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_TEST_TMUX_CALLS:-}" ]; then
  printf 'TMUX %s\n' "$*" >> "$FM_TEST_TMUX_CALLS"
fi
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  has-session|display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows|new-session|new-window|kill-window) exit 0 ;;
  send-keys)
    if [ -n "${FM_TEST_LAUNCH_LOG:-}" ]; then
      printf 'LAUNCH %s\n' "$*" >> "$FM_TEST_LAUNCH_LOG"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # Stateful fake herdr: the same modeled behaviors the fm-backend-herdr suite
  # verified against the real binary (workspace create seeds a default tab and
  # returns its ids in the same response; agent start SPLITS the target tab
  # into a new agent pane; pane close removes a single-pane tab), extended
  # with the agent-start argv log the cloud lane asserts its Herdr tracking
  # endpoint through. Backed by a JSON state file at $FM_FAKE_HERDR_STATE.
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
LOG="${FM_HERDR_LOG:?}"
STATE="${FM_FAKE_HERDR_STATE:?}"
{
  printf 'HERDR_SESSION=%s' "${HERDR_SESSION:-}"
  for a in "$@"; do printf '\x1f%s' "$a"; done
  printf '\n'
} >> "$LOG"

jq_state() { jq "$@" "$STATE"; }
save() { local tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }

cmd=${1:-}; sub=${2:-}
ws=""; label=""; tab=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --tab) tab=${args[$((i+1))]:-} ;;
  esac
done

case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n'
    ;;
  "workspace list")
    jq_state '{result:{workspaces:.workspaces}}'
    ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list")
    jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}'
    ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "pane list")
    if [ -n "$ws" ]; then
      jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    else
      jq_state '{result:{panes:[.tabs[]|{pane_id:.pane_id, tab_id:.tab_id}]}}'
    fi
    ;;
  "session list")
    printf '{"sessions":[{"name":"default","running":true}]}\n'
    ;;
  "pane close")
    pane=${3:-}
    jq_state --arg p "$pane" '.tabs |= [.[]|select(.pane_id != $p)]' | save
    ;;
  "tab close")
    tab_target=${3:-}
    jq_state --arg t "$tab_target" '.tabs |= [.[]|select(.tab_id != $t)]' | save
    ;;
  "agent start")
    # Real herdr pane ids carry the workspace prefix (w1:p4); the recorded
    # endpoint target session:wsid:pane depends on that exact shape for its
    # later absence proof.
    n=$(jq_state -r '.next'); paneid="${tab%%:*}:p$n"
    jq_state --arg t "$tab" --arg paneid "$paneid" \
      '(.tabs[] | select(.tab_id == $t) | .pane_id) = $paneid
       | .next = (.next + 1)' | save
    printf '{"result":{"agent":{"pane_id":"%s","tab_id":"%s"}}}\n' "$paneid" "$tab"
    ;;
  "agent get")
    pane=${3:-}
    printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "$pane"
    ;;
  *) : ;;
esac
exit 0
SH
  chmod 755 "$fakebin/herdr"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = get ]; then
  printf '%s\n' "${FM_FAKE_TREEHOUSE_WORKTREE:?}"
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# The same hermetic provider protocol fixture the fm-worker-lifecycle suite
# drives: complete resource sets per slot, idempotency replay, and a bounded
# execution result, with cost metrics steered by FM_TEST_ACTUAL_USD so the
# queued-without-admission lane is reachable.
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
        "metrics": {
            "actual_usd": float(os.environ.get("FM_TEST_ACTUAL_USD", "100")),
            "forecast_usd": float(os.environ.get("FM_TEST_FORECAST_USD", "150")),
        },
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
    return {
        "id": "/fixture/slot/{}/{}".format(action["slot"], kind),
        "immutable_id": "{}-{}".format(kind, serial), "etag": "etag-{}".format(serial),
        "tags": tags(action),
    }

def complete_worker(action):
    resources = {}
    for kind in (
        "vm", "nic", "os-disk", "task-disk", "account-disk", "identity", "role-assignment",
        "state-container", "monitor-extension", "bootstrap-command", "task-command", "ttl-schedule",
        "global-reservation", "staging-request", "staging-result",
    ):
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
        "capacity_reservations": [], "conflicts": [], "metrics": metrics,
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

# make_cloud_case <name> <id>: home + committed project + detached worktree +
# fake tmux/treehouse + fixture provider + hermetic codex account home.
make_cloud_case() {
  local name=$1 id=$2 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config" "$home/treehouse-pools" \
    "$case_dir/codex-home" "$case_dir/pi-agent-home"
  chmod 755 "$case_dir"
  # Cloud dispatch packages the pi provider-account material for the worker's
  # encrypted account disk; the hermetic account home carries a fixture
  # credential so the persist step has something real to digest.
  printf '{"openai-codex":{"accountId":"fixture-account"}}\n' > "$case_dir/pi-agent-home/auth.json"
  chmod 600 "$case_dir/pi-agent-home/auth.json"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet --detach "$worktree"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - cloud placement test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$home/data/backlog.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  write_fixture_provider "$case_dir/provider.py"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/herdr.log"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$case_dir/herdr-state.json"
  printf '%s\n' "$case_dir|$home|$project|$worktree|$fakebin"
}

read_cloud_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4
  shift 4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_TREEHOUSE_ROOT="$home/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$home/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_WORKTREE="$worktree" \
    FM_TEST_LAUNCH_LOG="$case_dir/launch.log" \
    FM_TEST_TMUX_CALLS="$case_dir/tmux-calls.log" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HERDR_LOG="$case_dir/herdr.log" \
    FM_FAKE_HERDR_STATE="$case_dir/herdr-state.json" \
    CODEX_HOME="$case_dir/codex-home" \
    PI_CODING_AGENT_DIR="$case_dir/pi-agent-home" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

run_cloud_spawn() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4
  shift 4
  FM_SPAWN_CLOUD=azure \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    run_spawn "$case_dir" "$home" "$worktree" "$fakebin" "$@"
}

# --- tests ------------------------------------------------------------------

test_cloud_switch_off_keeps_the_local_path_and_metadata_shape() {
  local record id out status meta
  id=cloud-off-c1
  record=$(make_cloud_case off-lane "$id")
  read_cloud_case "$record"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a default spawn with the cloud switch off should succeed: $out"
  assert_contains "$out" "spawned $id" "the local spawn did not complete: $out"
  assert_contains "$out" "harness=codex" "the local spawn did not keep its configured harness: $out"
  assert_not_contains "$out" "placement=azure" "an off-switch spawn reported cloud placement: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_present "$meta" "the local spawn wrote no task metadata"
  assert_no_grep 'placement=' "$meta" "an off-switch spawn recorded a placement key"
  assert_no_grep 'account_home=' "$meta" "an off-switch unrouted spawn recorded account_home"
  assert_no_grep 'worktree_git_dir_identity=' "$meta" "an off-switch unrouted spawn recorded a worktree identity"
  assert_no_grep 'worker_assignment_generation=' "$meta" "an off-switch spawn recorded a worker assignment"
  assert_grep 'LAUNCH' "$CASE_DIR/launch.log" "the local spawn never typed its launch command"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" "an off-switch spawn touched the worker controller state"
  pass "cloud switch off keeps the spawn on the local lane with unchanged metadata keys"
}

test_cloud_spawn_places_worker_and_runs_the_entrypoint() {
  local record id out status meta deadline
  id=cloud-on-c2
  record=$(make_cloud_case assigned-lane "$id")
  read_cloud_case "$record"
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a cloud spawn against an admitting provider should succeed: $out"
  assert_contains "$out" "spawned $id" "the cloud spawn did not complete: $out"
  assert_contains "$out" "placement=azure worker=executing" "the cloud spawn did not reach the executing state: $out"
  # The cloud lane is pi-codex only: config/crew-harness says codex, and the
  # cloud lane must bypass it unconditionally.
  assert_contains "$out" "harness=pi" "the cloud spawn did not select the pi-codex runtime: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'placement=azure' "$meta" "the cloud spawn did not record placement=azure"
  assert_grep 'harness=pi' "$meta" "the cloud spawn did not record the pi-codex runtime"
  assert_grep "account_home=$CASE_DIR/pi-agent-home" "$meta" "the cloud spawn did not record the pi coding-agent account home"
  assert_grep 'worktree_git_dir_identity=' "$meta" "the cloud spawn did not record the worktree Git-dir identity"
  assert_grep 'worktree_git_dir=' "$meta" "the cloud spawn did not record the worktree Git dir"
  # Herdr tracking endpoint: every cloud crewmate registers a real Herdr
  # endpoint running the cloud monitor, with ZERO tmux involvement anywhere
  # in the cloud lane.
  assert_grep 'window=' "$meta" "the cloud spawn lost its window key"
  assert_grep 'backend=herdr' "$meta" "the cloud spawn did not record its Herdr tracking backend"
  assert_grep 'herdr_session=' "$meta" "the cloud spawn did not record its Herdr session"
  assert_grep 'herdr_workspace_id=' "$meta" "the cloud spawn did not record its Herdr workspace"
  assert_grep 'herdr_tab_id=' "$meta" "the cloud spawn did not record its Herdr tab"
  assert_grep 'herdr_pane_id=' "$meta" "the cloud spawn did not record its Herdr pane"
  assert_grep "$(printf 'agent\x1fstart')" "$CASE_DIR/herdr.log" "the cloud spawn never registered a Herdr endpoint"
  assert_grep 'fm-spawn-cloud-monitor.sh' "$CASE_DIR/herdr.log" "the Herdr endpoint does not run the cloud monitor"
  assert_no_grep 'fm-spawn-cloud-monitor.sh' "$HOME_DIR/state/$id.worker-execute.log" \
    "the worker entrypoint was replaced by the local monitor command"
  test ! -s "$CASE_DIR/tmux-calls.log" || fail "a cloud spawn invoked tmux: $(cat "$CASE_DIR/tmux-calls.log")"
  assert_grep 'worker_assignment_generation=' "$meta" "the cloud spawn did not record its worker assignment generation"
  assert_no_grep 'LAUNCH' "$CASE_DIR/launch.log" "a cloud spawn typed a launch command into a local pane"
  assert_grep "\"task\":\"$id\"" "$HOME_DIR/state/azure-workers/controller.json" \
    "the worker controller never queued the cloud task"
  assert_grep '"status":"assigned"' "$HOME_DIR/state/azure-workers/controller.json" \
    "the cloud task was never assigned a worker"
  deadline=$(( $(date +%s) + 30 ))
  while :; do
    if [ -s "$HOME_DIR/state/$id.worker-result.json" ] \
      && grep -F '"exit_code":0' "$HOME_DIR/state/$id.worker-result.json" >/dev/null; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "the detached worker execution never produced its bounded result: $(cat "$HOME_DIR/state/$id.worker-execute.log" 2>/dev/null)"
    fi
    sleep 0.2
  done
  assert_grep '"request_digest"' "$HOME_DIR/state/$id.worker-result.json" \
    "the worker execution result is not digest-bound"
  pass "cloud spawn persists lifecycle bindings, assigns a worker, and runs the entrypoint remotely"
}

test_cloud_spawn_stays_durably_queued_without_admission() {
  local record id out status meta
  id=cloud-queue-c3
  record=$(make_cloud_case queued-lane "$id")
  read_cloud_case "$record"
  out=$(FM_TEST_ACTUAL_USD=2000 run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a cloud spawn whose admission is refused should still queue durably: $out"
  assert_contains "$out" "placement=azure worker=queued" "the refused-admission spawn did not report the queued state: $out"
  assert_contains "$out" "stays durably queued" "the refused-admission spawn did not surface the queued notice: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'placement=azure' "$meta" "the queued cloud spawn did not record placement=azure"
  assert_no_grep 'worker_assignment_generation=' "$meta" "a queued cloud spawn recorded a worker assignment"
  assert_grep "\"task\":\"$id\"" "$HOME_DIR/state/azure-workers/controller.json" \
    "the refused-admission task is not durably queued in the controller"
  assert_no_grep '"status":"assigned"' "$HOME_DIR/state/azure-workers/controller.json" \
    "a refused-admission task was assigned a worker anyway"
  assert_absent "$HOME_DIR/state/$id.worker-result.json" "a queued cloud spawn started an execution"
  pass "admission refusal leaves the cloud task durably queued and the spawn honest about it"
}

test_cloud_spawn_config_file_default_and_env_override() {
  local record id out status meta
  id=cloud-cfg-c4
  record=$(make_cloud_case config-lane "$id")
  read_cloud_case "$record"
  printf 'azure\n' > "$HOME_DIR/config/spawn-cloud"
  out=$(FM_TEST_ACTUAL_USD=2000 \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $CASE_DIR/provider.py" \
    FIXTURE_STATE="$CASE_DIR/provider-state.json" \
    PI_CODING_AGENT_DIR="$CASE_DIR/pi-agent-home" \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a config-file cloud spawn should succeed: $out"
  assert_contains "$out" "placement=azure" "config/spawn-cloud did not route the spawn to azure: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'placement=azure' "$meta" "config/spawn-cloud did not record placement=azure"
  id=cloud-cfg-c5
  mkdir -p "$HOME_DIR/data/$id"
  printf 'brief for %s\n' "$id" > "$HOME_DIR/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - cloud placement test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$HOME_DIR/data/backlog.md"
  out=$(FM_SPAWN_CLOUD=off run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "FM_SPAWN_CLOUD=off should override the config file: $out"
  assert_not_contains "$out" "placement=azure" "FM_SPAWN_CLOUD=off did not override config/spawn-cloud: $out"
  assert_no_grep 'placement=' "$HOME_DIR/state/$id.meta" "an env-overridden local spawn recorded a placement key"
  assert_grep 'LAUNCH' "$CASE_DIR/launch.log" "the env-overridden local spawn never typed its launch command"
  pass "config/spawn-cloud sets the durable default and FM_SPAWN_CLOUD overrides it per spawn"
}

test_cloud_spawn_refuses_unknown_switch_value() {
  local record id out status
  id=cloud-bad-c6
  record=$(make_cloud_case bad-value "$id")
  read_cloud_case "$record"
  out=$(FM_SPAWN_CLOUD=bogus run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an unknown cloud placement value should refuse the spawn: $out"
  assert_contains "$out" "unknown cloud placement 'bogus'" "the refusal did not name the bad value: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused cloud switch value still wrote task metadata"
  pass "an unknown cloud placement value fails closed before any mutation"
}

test_cloud_spawn_fails_closed_when_the_lifecycle_refuses_the_request() {
  local record id out status
  id=cloud-noenv-c7
  record=$(make_cloud_case refused-request "$id")
  read_cloud_case "$record"
  # FM_SPAWN_CLOUD=azure without the FM_AZURE_* identity environment: the
  # lifecycle refuses the request, so the spawn must roll back rather than
  # leave a lane that exists nowhere.
  out=$(FM_SPAWN_CLOUD=azure run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a cloud spawn whose worker request is refused should fail: $out"
  assert_contains "$out" "cloud worker request was refused" "the refusal did not surface the request failure: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused cloud spawn left task metadata behind"
  assert_no_grep 'LAUNCH' "$CASE_DIR/launch.log" "a refused cloud spawn launched a local lane anyway"
  pass "a refused worker request rolls the spawn back instead of stranding the task"
}

test_cloud_switch_refuses_non_pi_harness() {
  local record id out status
  id=cloud-hn-c10
  record=$(make_cloud_case harness-conflict "$id")
  read_cloud_case "$record"
  out=$(FM_SPAWN_CLOUD=azure run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --harness claude)
  status=$?
  expect_code 1 "$status" "cloud placement with a claude harness should refuse: $out"
  assert_contains "$out" "runs only the pi-codex runtime" \
    "the refusal did not name the pi-codex contract: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused non-pi cloud spawn wrote task metadata"
  pass "cloud placement refuses non-pi harnesses instead of wiring them into workers"
}

test_cloud_switch_refuses_explicit_backend() {
  local record id out status
  id=cloud-be-c8
  record=$(make_cloud_case backend-conflict "$id")
  read_cloud_case "$record"
  out=$(FM_SPAWN_CLOUD=azure run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --backend zellij)
  status=$?
  expect_code 1 "$status" "cloud placement with an explicit --backend should refuse: $out"
  assert_contains "$out" "--backend cannot be combined with cloud placement" \
    "the refusal did not explain the backend conflict: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused backend/cloud combination wrote task metadata"
  pass "cloud placement refuses an explicit local backend selection"
}

test_cloud_switch_off_and_on_share_the_same_base_metadata() {
  # The azure lane must be purely ADDITIVE over the local lane's metadata: the
  # same base keys in the same order, plus the placement block. This pins the
  # byte-compatibility contract for every existing meta consumer.
  local record id out meta base
  id=cloud-shape-c9
  record=$(make_cloud_case shape-lane "$id")
  read_cloud_case "$record"
  out=$(FM_TEST_ACTUAL_USD=2000 run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  expect_code 0 $? "the shape-lane cloud spawn should succeed: $out"
  meta="$HOME_DIR/state/$id.meta"
  base=$(grep -v -e '^placement=' -e '^worktree_git_dir=' -e '^worktree_git_dir_identity=' \
    -e '^account_home=' "$meta")
  for key in window worktree project harness kind mode yolo tasktmp tasktmp_phase model effort generation_id report_required; do
    case "$base" in
      *"$key="*) : ;;
      *) fail "cloud metadata lost the base key '$key'" ;;
    esac
  done
  pass "cloud metadata stays additive over the local metadata shape"
}

test_cloud_monitor_launch_carries_fm_home() {
  # The Herdr server starts endpoint panes in a closed environment; the
  # monitor's launch string must therefore carry FM_HOME inline or the
  # tracking pane dies at spawn time on the monitor's required-env guard.
  local record id out
  id=cloud-mon-c11
  record=$(make_cloud_case monitor-env "$id")
  read_cloud_case "$record"
  out=$(FM_TEST_ACTUAL_USD=2000 run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  expect_code 0 $? "the monitor-env cloud spawn should succeed: $out"
  grep -F 'fm-spawn-cloud-monitor.sh' "$CASE_DIR/herdr.log" | grep -qF "FM_HOME=$HOME_DIR" \
    || fail "the Herdr monitor launch string does not carry FM_HOME: $(grep -F 'fm-spawn-cloud-monitor.sh' "$CASE_DIR/herdr.log" | head -1)"
  grep -F 'fm-spawn-cloud-monitor.sh' "$CASE_DIR/herdr.log" | grep -qF "FM_STATE_OVERRIDE=$HOME_DIR/state" \
    || fail "the Herdr monitor launch string does not carry the spawn's state directory"
  pass "the cloud monitor launch string carries FM_HOME and the state override for the closed Herdr pane environment"
}

test_respawn_sweeps_stale_cloud_artifacts() {
  # Cloud state files are keyed by task ID while the queue is keyed by
  # ID@GENERATION. A re-spawn that inherits the previous generation's result
  # would kill the new monitor at once, and an inherited dispatch marker
  # would make BOTH owners stand down, so the new worker would never run its
  # entrypoint. The spawn must sweep them before the tracking pane exists.
  local record id out
  id=cloud-swp-c14
  record=$(make_cloud_case respawn-sweep "$id")
  read_cloud_case "$record"
  printf '{"stale":"previous-generation"}\n' > "$HOME_DIR/state/$id.worker-result.json"
  : > "$HOME_DIR/state/$id.cloud-execute-dispatched"
  printf 'stale execute log\n' > "$HOME_DIR/state/$id.worker-execute.log"
  printf 'stale entrypoint\n' > "$HOME_DIR/state/$id.cloud-entrypoint"
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  expect_code 0 $? "a spawn over stale cloud artifacts should succeed: $out"
  assert_contains "$out" "placement=azure worker=executing" \
    "the spawn over stale artifacts did not reach the executing state: $out"
  local deadline
  deadline=$(( $(date +%s) + 30 ))
  while :; do
    if [ -s "$HOME_DIR/state/$id.worker-result.json" ] \
      && grep -F '"exit_code":0' "$HOME_DIR/state/$id.worker-result.json" >/dev/null 2>&1; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      fail "the re-spawn never produced a fresh bounded result: $(cat "$HOME_DIR/state/$id.worker-execute.log" 2>/dev/null)"
    fi
    sleep 0.2
  done
  grep -F 'previous-generation' "$HOME_DIR/state/$id.worker-result.json" >/dev/null 2>&1 \
    && fail "the fresh result still carries the stale generation's content"
  grep -F 'stale entrypoint' "$HOME_DIR/state/$id.cloud-entrypoint" >/dev/null 2>&1 \
    && fail "the stale entrypoint survived the re-spawn sweep"
  pass "a re-spawn sweeps the previous generation's cloud artifacts before the tracking pane exists"
}

test_queued_spawn_converges_through_the_monitor() {
  # A spawn whose admission is refused leaves the request durably queued; a
  # LATER reconcile assigns the worker after the spawn process is gone. The
  # tracking monitor must then dispatch the persisted entrypoint through the
  # real bounded execute, exactly once.
  local record id out meta deadline monitor_pid
  id=cloud-cvg-c12
  record=$(make_cloud_case converge-lane "$id")
  read_cloud_case "$record"
  out=$(FM_TEST_ACTUAL_USD=2000 run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  expect_code 0 $? "the queued spawn should succeed: $out"
  assert_contains "$out" "placement=azure worker=queued" "the spawn did not stay queued: $out"
  assert_present "$HOME_DIR/state/$id.cloud-entrypoint" "a queued cloud spawn did not persist its entrypoint"
  test -s "$HOME_DIR/state/$id.cloud-entrypoint" || fail "the persisted entrypoint is empty"
  assert_present "$HOME_DIR/state/$id.cloud-env" "a queued cloud spawn did not persist its azure environment"
  assert_grep 'export FM_AZURE_SUBSCRIPTION_ID=' "$HOME_DIR/state/$id.cloud-env" \
    "the persisted environment lost the subscription id"
  assert_grep 'export FM_WORKER_PROVIDER_COMMAND=' "$HOME_DIR/state/$id.cloud-env" \
    "the persisted environment lost the provider command override"
  assert_absent "$HOME_DIR/state/$id.cloud-execute-dispatched" "a queued spawn claimed the execute dispatch"
  assert_absent "$HOME_DIR/state/$id.worker-result.json" "a queued spawn started an execution"
  # Later operator reconcile with healthy admission evidence: converges to
  # assigned, but (by design) runs no entrypoint itself.
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $CASE_DIR/provider.py" \
    FIXTURE_STATE="$CASE_DIR/provider-state.json" \
    "$ROOT/bin/fm-worker-lifecycle.sh" reconcile --apply --confirm-subscription "$SUB" 2>&1)
  expect_code 0 $? "the later reconcile should converge the queued request: $out"
  assert_grep '"status":"assigned"' "$HOME_DIR/state/azure-workers/controller.json" \
    "the later reconcile did not assign the queued task"
  assert_absent "$HOME_DIR/state/$id.worker-result.json" "reconcile itself started an execution"
  # The monitor (in the closed Herdr pane environment: FM_HOME only) must
  # pick up the assignment and drive the real lifecycle execute.
  local spawn_generation
  spawn_generation=$(sed -n 's/^generation_id=//p' "$HOME_DIR/state/$id.meta" | head -1)
  test -n "$spawn_generation" || fail "the queued spawn recorded no generation_id"
  env -u FM_WORKER_PROVIDER_COMMAND FM_HOME="$HOME_DIR" \
    FIXTURE_STATE="$CASE_DIR/provider-state.json" \
    FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" "$spawn_generation" \
    > "$CASE_DIR/monitor.log" 2>&1 &
  monitor_pid=$!
  deadline=$(( $(date +%s) + 30 ))
  while :; do
    if [ -s "$HOME_DIR/state/$id.worker-result.json" ] \
      && grep -F '"exit_code":0' "$HOME_DIR/state/$id.worker-result.json" >/dev/null 2>&1; then
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      kill "$monitor_pid" 2>/dev/null || true
      fail "the monitor never converged the assigned task into a bounded result: $(cat "$CASE_DIR/monitor.log" 2>/dev/null; cat "$HOME_DIR/state/$id.worker-execute.log" 2>/dev/null)"
    fi
    sleep 0.2
  done
  wait "$monitor_pid" 2>/dev/null || true
  assert_present "$HOME_DIR/state/$id.cloud-execute-dispatched" "the monitor dispatched without claiming the marker"
  assert_grep 'dispatching bounded execute' "$CASE_DIR/monitor.log" "the monitor did not announce its converged dispatch"
  assert_grep '"request_digest"' "$HOME_DIR/state/$id.worker-result.json" \
    "the converged execution result is not digest-bound"
  assert_no_grep 'fm-spawn-cloud-monitor.sh' "$HOME_DIR/state/$id.worker-execute.log" \
    "the converged entrypoint was replaced by the local monitor command"
  pass "a queued spawn converges through the monitor into a digest-bound execute, exactly once"
}

test_monitor_stands_down_when_dispatch_already_claimed() {
  # A pre-existing dispatch marker means the spawn (or an earlier monitor)
  # already owns the execute; the monitor must never dispatch a second one.
  local record id monitor_pid
  id=cloud-cvg-c13
  record=$(make_cloud_case claimed-lane "$id")
  read_cloud_case "$record"
  mkdir -p "$HOME_DIR/state/azure-workers"
  printf '{"queue":{"%s@gen-1":{"status":"assigned","assignment_generation":"asg-00000001"}}}\n' "$id" \
    > "$HOME_DIR/state/azure-workers/controller.json"
  printf 'echo entrypoint\n' > "$HOME_DIR/state/$id.cloud-entrypoint"
  printf 'export FM_AZURE_SUBSCRIPTION_ID=%s\n' "$SUB" > "$HOME_DIR/state/$id.cloud-env"
  : > "$HOME_DIR/state/$id.cloud-execute-dispatched"
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/monitor.log" 2>&1 &
  monitor_pid=$!
  sleep 3
  kill "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
  assert_absent "$HOME_DIR/state/$id.worker-execute.log" "a claimed dispatch was executed a second time"
  assert_absent "$HOME_DIR/state/$id.worker-result.json" "a claimed dispatch produced a second result"
  assert_grep 'worker=assigned' "$CASE_DIR/monitor.log" "the monitor did not keep rendering the assigned state"
  pass "the monitor stands down when the execute dispatch is already claimed"
}

test_cloud_switch_off_keeps_the_local_path_and_metadata_shape
test_cloud_spawn_places_worker_and_runs_the_entrypoint
test_cloud_spawn_stays_durably_queued_without_admission
test_cloud_monitor_launch_carries_fm_home
test_respawn_sweeps_stale_cloud_artifacts
test_queued_spawn_converges_through_the_monitor
test_monitor_stands_down_when_dispatch_already_claimed
test_cloud_spawn_config_file_default_and_env_override
test_cloud_spawn_refuses_unknown_switch_value
test_cloud_spawn_fails_closed_when_the_lifecycle_refuses_the_request
test_cloud_switch_refuses_non_pi_harness
test_cloud_switch_refuses_explicit_backend

test_cloud_switch_off_and_on_share_the_same_base_metadata

echo "# fm-spawn-cloud.test.sh: all assertions passed"
