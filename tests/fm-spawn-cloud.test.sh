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

# The fixture Pi credential pool.  The cloud lane's canonical account home is
# pooled, and every placement snapshots one load-balanced profile into its own
# writable home, so the fixture carries several complete OAuth profiles.
fm_spawn_cloud_write_pi_pool() {  # <auth.json path> [account prefix]
  python3 - "$1" "${2:-fixture}" <<'PY'
import json
import sys

prefix = sys.argv[2]
pool = {}
for index in range(1, 7):
    name = "openai-codex" if index == 1 else "openai-codex-{}".format(index)
    pool[name] = {
        "type": "oauth", "access": "{}-access-{}".format(prefix, index),
        "refresh": "{}-refresh-{}".format(prefix, index),
        "accountId": "{}-account-{}".format(prefix, index),
        "expires": 4102444800000,
    }
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(pool, handle, sort_keys=True, indent=2)
PY
  chmod 600 "$1"
}
SUB=11111111-1111-4111-8111-111111111111
OTHER_SUB=22222222-2222-4222-8222-222222222222
PRIVATE_ADMIN_EMAIL=autoload-private@example.invalid

write_azure_controller_config() {  # <path> [subscription] [prefix]
  local path=$1 subscription=${2:-$SUB} prefix=${3:-fmtest}
  cat > "$path" <<EOF
# Literal private controller values for this hermetic Firstmate home.
FM_AZURE_TENANT_ID=33333333-3333-4333-8333-333333333333
FM_AZURE_SUBSCRIPTION_ID=$subscription
FM_AZURE_ADMIN_EMAIL=$PRIVATE_ADMIN_EMAIL
FM_AZURE_ADMIN_USERNAME=fmfixture
FM_AZURE_ADMIN_SSH_PUBLIC_KEY=ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFirstmateFixtureKey fixture@example.invalid
FM_AZURE_RUNNER_OPERATOR_OBJECT_ID=44444444-4444-4444-8444-444444444444
FM_AZURE_OWNER_TAG=owner
FM_AZURE_NAMING_PREFIX=$prefix
FM_AZURE_STORAGE_NAME=fmteststorage001
FM_AZURE_KEY_VAULT_NAME=fmtest-key-vault-001
FM_AZURE_DEPLOYMENT_GENERATION=dep-one
FM_AZURE_BUDGET_START_DATE=2026-01-01
FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0
EOF
  chmod 600 "$path"
}

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
if [ -n "${FM_TEST_TREEHOUSE_CALLS:-}" ]; then
  printf 'TREEHOUSE %s\n' "$*" >> "$FM_TEST_TREEHOUSE_CALLS"
fi
if [ "${1:-}" = get ]; then
  selected=${FM_FAKE_TREEHOUSE_WORKTREE:?}
  # Compartment-child fixture: model Treehouse's root-scoped pool selection.
  # The primary and task homes intentionally carry same-named repositories
  # with different Git common identities. A managed source configured with the
  # primary root therefore leases the foreign primary-pool worktree; only the
  # task-home root returns the compartment project's exact worktree.
  if [ -n "${FM_FAKE_TREEHOUSE_TASK_HOME:-}" ]; then
    if grep -Fq "${FM_FAKE_TREEHOUSE_TASK_HOME}" treehouse.toml 2>/dev/null; then
      selected=${FM_FAKE_TREEHOUSE_WORKTREE:?}
    else
      selected=${FM_FAKE_TREEHOUSE_FOREIGN_WORKTREE:?}
    fi
  fi
  printf '%s\n' "$selected"
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
    if action.get("role") == "secondmate":
        # A compartment VM carries the compartment tag set; the crewmate tags
        # below would be a lie in the cloud's own metadata.
        return {
            "workload": "firstmate", "firstmate-role": "secondmate-compartment",
            "deployment-generation": action["deployment_generation"], "cleanup-owner": action["owner"],
            "worker-slot": str(action["slot"]), "home-binding": bindings["home_binding"],
            "task-binding": bindings["task"], "task-generation": bindings["task_generation"],
            "assignment-generation": bindings["assignment_generation"],
            "account-binding": bindings["account_binding"],
            "worktree-binding": bindings["worktree_binding"],
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
            if request_value.get("outcome_expected"):
                # The fixture crewmate commits nothing, which is the disposition
                # a supervisor that understands the outcome contract reports.
                execution.update({
                    "outcome_present": False, "outcome_error": "",
                    "outcome_commits": 0, "outcome_sha256": "", "outcome_bytes": 0,
                    "outcome_sink": "", "outcome_uncommitted_changes": False,
                })
                if request_value.get("return_contract"):
                    execution.update({
                        "return_present": True,
                        "return_ref": "refs/fm-return/" + action["request_digest"][:32],
                        "return_commit": "c" * 40,
                        "return_manifest_sha256": "d" * 64,
                        "outcome_tip": request_value["repository_generation"],
                    })
            execution["streams_persisted"] = True
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
  fm_spawn_cloud_write_pi_pool "$case_dir/pi-agent-home/auth.json"
  printf '%s\n' codex > "$home/config/crew-harness"
  printf '%s\n' manual > "$home/config/backlog-backend"
  write_azure_controller_config "$home/config/azure-controller.env"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet --detach "$worktree"
  touch "$home/state/.last-watcher-beat"
  mkdir -p "$home/data/$id"
  printf 'brief for %s; write %s/data/%s/completion.md and %s/state/%s.status\n' \
    "$id" "$home" "$id" "$home" "$id" > "$home/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - cloud placement test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$home/data/backlog.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  write_fixture_provider "$case_dir/provider.py"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/treehouse-calls.log"
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
    FM_TEST_TREEHOUSE_CALLS="$case_dir/treehouse-calls.log" \
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
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    run_spawn "$case_dir" "$home" "$worktree" "$fakebin" "$@"
}

run_azure_only_config_spawn() {
  local case_dir=$1 home=$2 worktree=$3 fakebin=$4
  shift 4
  (
    unset FM_SPAWN_CLOUD FM_SPAWN_SECONDMATE_CLOUD
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
      FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
      FM_AZURE_OWNER_TAG=owner \
      FM_AZURE_NAMING_PREFIX=fmtest \
      FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
      FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
      FIXTURE_STATE="$case_dir/provider-state.json" \
      run_spawn "$case_dir" "$home" "$worktree" "$fakebin" "$@"
  )
}

# --- tests ------------------------------------------------------------------

test_cloud_switch_off_keeps_the_local_path_and_metadata_shape() {
  local record id out status meta
  id=cloud-off-c1
  record=$(make_cloud_case off-lane "$id")
  read_cloud_case "$record"
  printf 'this is deliberately invalid Azure config\n' > "$HOME_DIR/config/azure-controller.env"
  chmod 600 "$HOME_DIR/config/azure-controller.env"
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
  pass "cloud switch off ignores even an invalid Azure config and keeps local metadata unchanged"
}

test_cloud_spawn_places_worker_and_runs_the_entrypoint() {
  local record id out status meta deadline
  id=cloud-on-c2
  record=$(make_cloud_case assigned-lane "$id")
  read_cloud_case "$record"
  # The durable source deliberately disagrees on two controller identities.
  # Explicit invocation values must win without preventing config-only values
  # from loading, and none of those private values may leak into user surfaces.
  write_azure_controller_config "$HOME_DIR/config/azure-controller.env" "$OTHER_SUB" filecfg
  out=$(FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_NAMING_PREFIX=fmtest \
    run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a cloud spawn against an admitting provider should succeed: $out"
  assert_contains "$out" "spawned $id" "the cloud spawn did not complete: $out"
  assert_contains "$out" "placement=azure worker=executing" "the cloud spawn did not reach the executing state: $out"
  # The cloud lane is pi-codex only: config/crew-harness says codex, and the
  # cloud lane must bypass it unconditionally.
  assert_contains "$out" "harness=pi" "the cloud spawn did not select the pi-codex runtime: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'placement=azure' "$meta" "the cloud spawn did not record placement=azure"
  assert_grep "export FM_AZURE_SUBSCRIPTION_ID=$SUB" "$HOME_DIR/state/$id.cloud-env" \
    "the explicit subscription did not win over the durable source"
  assert_grep 'export FM_AZURE_NAMING_PREFIX=fmtest' "$HOME_DIR/state/$id.cloud-env" \
    "the explicit naming prefix did not win over the durable source"
  assert_grep "export FM_AZURE_ADMIN_EMAIL=$PRIVATE_ADMIN_EMAIL" "$HOME_DIR/state/$id.cloud-env" \
    "a config-only allowlisted value was not loaded for the dispatched monitor"
  assert_not_contains "$out" "$PRIVATE_ADMIN_EMAIL" "spawn output leaked a private controller value: $out"
  assert_no_grep "$PRIVATE_ADMIN_EMAIL" "$meta" "task metadata leaked a private controller value"
  assert_no_grep "$PRIVATE_ADMIN_EMAIL" "$HOME_DIR/state/$id.cloud-payload/brief.md" \
    "the generated worker brief leaked a private controller value"
  assert_no_grep "$PRIVATE_ADMIN_EMAIL" "$CASE_DIR/herdr.log" \
    "the backend launch log leaked a private controller value"
  assert_grep 'harness=pi' "$meta" "the cloud spawn did not record the pi-codex runtime"
  assert_grep "account_home=$CASE_DIR/pi-agent-home" "$meta" "the cloud spawn did not record the pi coding-agent account home"
  assert_grep '--fast' "$HOME_DIR/state/$id.cloud-entrypoint" "the cloud worker entrypoint did not force Fast Mode"
  assert_grep '/mnt/task/.fm-return/data/' "$HOME_DIR/state/$id.cloud-payload/brief.md" \
    "the cloud brief did not map its report path into the authorized return root"
  assert_grep '/mnt/task/.fm-return/state/' "$HOME_DIR/state/$id.cloud-payload/brief.md" \
    "the cloud brief did not map its status path into the authorized return root"
  assert_no_grep "$HOME_DIR/data/$id/completion.md" "$HOME_DIR/state/$id.cloud-payload/brief.md" \
    "the staged cloud brief still names the unavailable local report path"
  assert_grep 'worktree_git_dir_identity=' "$meta" "the cloud spawn did not record the worktree Git-dir identity"
  assert_grep 'worktree_git_dir=' "$meta" "the cloud spawn did not record the worktree Git dir"
  # The controller selected ONE profile out of that pool, and the credential
  # this worker actually receives is that profile's alone. Staging the pool
  # would put four accounts on the guest and let pi pick the first slot, which
  # is a shared-account placement no matter what the queue records.
  assert_grep 'worker_account_profile=' "$meta" "the cloud spawn did not record its provider-account snapshot profile"
  assert_grep "worker_account_home=$HOME_DIR/state/azure-workers/accounts/" "$meta" \
    "the cloud spawn did not record the controller-projected account home it was placed on"
  python3 - "$meta" "$HOME_DIR/state/$id.cloud-account/auth.json" \
    "$HOME_DIR/state/azure-workers/controller.json" "$id" <<'PY' \
    || fail "the staged provider credential is not the selected single-profile snapshot"
import json
import sys

meta_path, staged_path, controller_path, task = sys.argv[1:]
meta = {}
for line in open(meta_path, encoding="utf-8"):
    if "=" in line:
        key, value = line.rstrip("\n").split("=", 1)
        meta[key] = value
staged = json.load(open(staged_path, encoding="utf-8"))
assert list(staged) == ["openai-codex"], sorted(staged)
snapshot = json.load(open(meta["worker_account_home"] + "/auth.json", encoding="utf-8"))
assert staged == snapshot, "the staged credential is not the assignment snapshot"
state = json.load(open(controller_path, encoding="utf-8"))
item = next(entry for entry in state["queue"].values() if entry["task"] == task)
assert item["account_profile"] == meta["worker_account_profile"], (item, meta)
assert item["account_home"] == meta["worker_account_home"], (item, meta)
assert item["account_pool_home"] == meta["account_home"], (item, meta)
# The pool it was drawn from really did hold more than one account, so this
# proves a SELECTION happened rather than there being nothing to choose.
pool = json.load(open(meta["account_home"] + "/auth.json", encoding="utf-8"))
assert len(pool) > 1, sorted(pool)
assert snapshot["openai-codex"]["accountId"] == pool[item["account_profile"]]["accountId"], item
PY
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

test_cloud_spawn_uses_the_dedicated_azure_account_pool() {
  local record id out status meta azure_home
  id=cloud-pool-c2b
  record=$(make_cloud_case dedicated-account-pool "$id")
  read_cloud_case "$record"
  azure_home="$CASE_DIR/azure-pi-agent-home"
  mkdir -p "$azure_home"
  fm_spawn_cloud_write_pi_pool "$azure_home/auth.json" azure
  printf '%s\n' "$azure_home" > "$HOME_DIR/config/azure-worker-account-home"
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a cloud spawn with a dedicated account pool should succeed: $out"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep "account_home=$azure_home" "$meta" "the cloud spawn ignored config/azure-worker-account-home"
  python3 - "$meta" "$HOME_DIR/state/azure-workers/controller.json" \
    "$CASE_DIR/pi-agent-home/auth.json" "$azure_home/auth.json" "$id" <<'PY' \
    || fail "the controller did not snapshot from the dedicated Azure pool"
import json
from pathlib import Path
import sys

meta_path, controller_path, local_path, azure_path, task = sys.argv[1:]
meta = {}
for line in open(meta_path, encoding="utf-8"):
    if "=" in line:
        key, value = line.rstrip("\n").split("=", 1)
        meta[key] = value
state = json.load(open(controller_path, encoding="utf-8"))
item = next(entry for entry in state["queue"].values() if entry["task"] == task)
local_pool = json.load(open(local_path, encoding="utf-8"))
azure_pool = json.load(open(azure_path, encoding="utf-8"))
assert item["account_pool_home"] == meta["account_home"]
assert item["account_pool_home"] == str(Path(azure_path).parent)
assert azure_pool[item["account_profile"]]["accountId"].startswith("azure-account-")
assert azure_pool[item["account_profile"]]["accountId"] != local_pool[item["account_profile"]]["accountId"]
PY
  pass "config/azure-worker-account-home isolates Azure credentials from the primary Pi home"
}

test_cloud_spawn_refuses_an_unsafe_azure_account_pool_path() {
  local record id out status
  id=cloud-pool-bad-c2c
  record=$(make_cloud_case unsafe-account-pool "$id")
  read_cloud_case "$record"
  printf '%s\n' relative/pi-agent-home > "$HOME_DIR/config/azure-worker-account-home"
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a relative Azure account-pool path should fail closed: $out"
  assert_contains "$out" "must name an absolute path" "the refusal did not explain the account-pool path contract: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "an unsafe Azure account-pool path still wrote task metadata"
  pass "an unsafe Azure account-pool path fails closed before spawn mutation"
}

test_cloud_spawn_refuses_a_gap_in_the_azure_account_pool() {
  local record id out status azure_home
  id=cloud-pool-gap-c2e
  record=$(make_cloud_case incomplete-account-pool "$id")
  read_cloud_case "$record"
  azure_home="$CASE_DIR/azure-pi-agent-home"
  mkdir -p "$azure_home"
  fm_spawn_cloud_write_pi_pool "$azure_home/auth.json" azure
  python3 - "$azure_home/auth.json" <<'PY'
import json
import sys
path = sys.argv[1]
pool = json.load(open(path, encoding="utf-8"))
del pool["openai-codex-4"]
with open(path, "w", encoding="utf-8") as handle:
    json.dump(pool, handle)
PY
  printf '%s\n' "$azure_home" > "$HOME_DIR/config/azure-worker-account-home"
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a gapped Azure account pool should fail closed: $out"
  assert_contains "$out" "profiles must be gap-free" "the refusal did not explain the profile-numbering contract: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a gapped Azure pool still wrote task metadata"
  pass "Azure placement requires gap-free account numbering while allowing pool growth"
}

test_cloud_spawn_refuses_a_credential_that_could_refresh_on_the_guest() {
  local record id out status
  id=cloud-expiring-c2d
  record=$(make_cloud_case expiring-account "$id")
  read_cloud_case "$record"
  python3 - "$CASE_DIR/pi-agent-home/auth.json" <<'PY'
import json
import sys
import time

path = sys.argv[1]
pool = json.load(open(path, encoding="utf-8"))
for entry in pool.values():
    entry["expires"] = int((time.time() + 3600) * 1000)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(pool, handle, sort_keys=True, indent=2)
PY
  out=$(run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a credential that could refresh during the worker lifetime should fail closed: $out"
  assert_contains "$out" "lacks twelve hours of access-token headroom" \
    "the refusal did not explain the guest refresh boundary: $out"
  assert_absent "$HOME_DIR/state/$id.cloud-account/auth.json" \
    "a near-expiry credential was left staged after refusal"
  if [ -f "$HOME_DIR/state/azure-workers/controller.json" ]; then
    assert_no_grep "\"task\":\"$id\"" "$HOME_DIR/state/azure-workers/controller.json" \
      "the refused near-expiry pool kept an assignment projection"
  fi
  pass "cloud staging prevents a guest from becoming a second OAuth refresh authority"
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

test_azure_only_routes_every_new_ship_and_scout_without_local_fallback() {
  local kind record id out status meta args
  for kind in ship scout; do
    id="azure-only-${kind}-p1"
    record=$(make_cloud_case "azure-only-$kind" "$id")
    read_cloud_case "$record"
    printf 'azure-only\n' > "$HOME_DIR/config/spawn-cloud"
    args=()
    [ "$kind" != scout ] || args=(--scout)
    out=$(FM_TEST_ACTUAL_USD=2000 \
      run_azure_only_config_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
      "$id" "$PROJECT_DIR" ${args[@]+"${args[@]}"})
    status=$?
    expect_code 0 "$status" "azure-only $kind should stay durably queued when Azure admission is unavailable: $out"
    assert_contains "$out" "placement=azure worker=queued" \
      "azure-only $kind did not stay on the queued Azure lane: $out"
    assert_contains "$out" "harness=pi" \
      "azure-only $kind did not use the pi-codex Azure runtime: $out"
    meta="$HOME_DIR/state/$id.meta"
    assert_grep 'placement=azure' "$meta" "azure-only $kind did not record Azure placement"
    assert_grep "kind=$kind" "$meta" "azure-only $kind recorded the wrong kind"
    assert_no_grep 'LAUNCH' "$CASE_DIR/launch.log" \
      "azure-only $kind fell back to a local agent while queued"
    assert_grep "\"task\":\"$id\"" "$HOME_DIR/state/azure-workers/controller.json" \
      "azure-only $kind was not durably queued in the controller"
  done
  pass "azure-only places every new ship and scout on Azure and queues without a local fallback"
}

test_azure_only_precedence_cannot_be_loosened_and_environment_can_tighten() {
  local value record id out status
  for value in '' off local; do
    id="azure-only-refuse-${value:-empty}-p2"
    record=$(make_cloud_case "azure-only-refuse-${value:-empty}" "$id")
    read_cloud_case "$record"
    printf 'azure-only\n' > "$HOME_DIR/config/spawn-cloud"
    out=$(FM_SPAWN_CLOUD="$value" \
      run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
    status=$?
    expect_code 1 "$status" "durable azure-only policy must refuse FM_SPAWN_CLOUD=${value:-<empty>}: $out"
    assert_contains "$out" "azure-only placement policy from config/spawn-cloud refuses FM_SPAWN_CLOUD" \
      "the durable-policy refusal did not name the conflicting environment value: $out"
    assert_absent "$HOME_DIR/state/$id.meta" "a refused placement override wrote task metadata"
    [ ! -s "$CASE_DIR/treehouse-calls.log" ] || fail "a refused placement override acquired a worktree"
    assert_absent "$HOME_DIR/state/azure-workers/controller.json" \
      "a refused placement override requested cloud capacity"
  done

  id=azure-only-env-tighten-p3
  record=$(make_cloud_case azure-only-env-tighten "$id")
  read_cloud_case "$record"
  printf 'local\n' > "$HOME_DIR/config/spawn-cloud"
  out=$(FM_SPAWN_CLOUD=azure-only FM_TEST_ACTUAL_USD=2000 \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $CASE_DIR/provider.py" \
    FIXTURE_STATE="$CASE_DIR/provider-state.json" \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "FM_SPAWN_CLOUD=azure-only should tighten an ordinary config value: $out"
  assert_contains "$out" "placement=azure worker=queued" \
    "the environment-tightened policy did not use Azure: $out"
  assert_no_grep 'LAUNCH' "$CASE_DIR/launch.log" \
    "the environment-tightened policy launched a local agent"
  pass "azure-only precedence is monotone: durable policy cannot be loosened and the environment may tighten"
}

test_azure_only_refuses_incompatible_and_recovery_routes_before_mutation() {
  local record id out status
  id=azure-only-refusal-matrix-p4
  record=$(make_cloud_case azure-only-refusal-matrix "$id")
  read_cloud_case "$record"
  printf 'azure-only\n' > "$HOME_DIR/config/spawn-cloud"
  mv "$CASE_DIR/pi-agent-home" "$CASE_DIR/pi-agent-home-unavailable"

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --harness claude)
  status=$?
  expect_code 1 "$status" "azure-only should refuse a non-pi harness before account preflight: $out"
  assert_contains "$out" "incompatible harness 'claude' was refused" \
    "non-pi harness refusal was not policy-specific: $out"

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" 'pi --fast')
  status=$?
  expect_code 1 "$status" "azure-only should refuse a raw launch before account preflight: $out"
  assert_contains "$out" "refuses raw launch commands" "raw launch refusal was not policy-specific: $out"

  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" --backend tmux)
  status=$?
  expect_code 1 "$status" "azure-only should refuse an explicit backend before account preflight: $out"
  assert_contains "$out" "refuses --backend" "backend refusal was not policy-specific: $out"

  for recovery in --resume-account --continue-account --recover-direct-account; do
    out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$recovery")
    status=$?
    expect_code 1 "$status" "azure-only should refuse $recovery before metadata or endpoint recovery: $out"
    assert_contains "$out" "because those routes start a local agent process" \
      "$recovery refusal did not name the prevented local process: $out"
  done

  assert_absent "$HOME_DIR/state/$id.meta" "a policy refusal wrote task metadata"
  [ ! -s "$CASE_DIR/treehouse-calls.log" ] || fail "a policy refusal acquired a worktree"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "a policy refusal launched a local endpoint"
  [ ! -s "$CASE_DIR/herdr.log" ] || fail "a policy refusal created a tracking endpoint"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" \
    "a policy refusal requested cloud capacity"
  assert_absent "$HOME_DIR/state/$id.cloud-account" \
    "a policy refusal copied provider credentials"
  pass "azure-only refuses raw, incompatible, backend, and local recovery routes before mutation"
}

test_azure_only_preserves_existing_local_and_unlanded_work() {
  local record id out status
  id=azure-only-existing-local-p5
  record=$(make_cloud_case azure-only-existing-local "$id")
  read_cloud_case "$record"
  printf 'azure-only\n' > "$HOME_DIR/config/spawn-cloud"
  printf 'unlanded local work\n' > "$WORKTREE_DIR/unlanded.txt"
  cat > "$HOME_DIR/state/$id.meta" <<EOF
window=firstmate:fm-$id
worktree=$WORKTREE_DIR
project=$PROJECT_DIR
harness=codex
kind=ship
generation_id=local-generation
EOF
  cp "$HOME_DIR/state/$id.meta" "$CASE_DIR/existing-local.meta.before"
  mv "$CASE_DIR/pi-agent-home" "$CASE_DIR/pi-agent-home-unavailable"
  out=$(run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "azure-only must refuse implicit migration of an existing local task: $out"
  assert_contains "$out" "will not migrate or reclassify existing local task $id" \
    "the refusal did not name preservation of the existing local task: $out"
  cmp -s "$CASE_DIR/existing-local.meta.before" "$HOME_DIR/state/$id.meta" \
    || fail "the existing local task metadata changed during refusal"
  assert_grep 'unlanded local work' "$WORKTREE_DIR/unlanded.txt" \
    "the existing unlanded work was removed during refusal"
  [ ! -s "$CASE_DIR/treehouse-calls.log" ] || fail "existing local preservation acquired another worktree"
  [ ! -s "$CASE_DIR/launch.log" ] || fail "existing local preservation started another local agent"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" \
    "existing local preservation reclassified the task into the cloud controller"
  pass "azure-only leaves existing local metadata, worktree, and unlanded work unchanged"
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

test_cloud_spawn_requires_safe_durable_controller_config_before_mutation() {
  local record id out status help
  id=cloud-noenv-c7
  record=$(make_cloud_case refused-request "$id")
  read_cloud_case "$record"

  rm -f "$HOME_DIR/config/azure-controller.env"
  out=$(FM_SPAWN_CLOUD=azure \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a cloud spawn with no durable controller config should fail: $out"
  assert_contains "$out" "private config is missing" "the refusal did not name the missing durable source: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a missing config still wrote task metadata"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" "a missing config still wrote controller state"
  test -z "$(find "$HOME_DIR/treehouse-pools" -mindepth 1 -print -quit 2>/dev/null)" \
    || fail "a missing config mutated the Treehouse pool"
  test ! -s "$CASE_DIR/herdr.log" || fail "a missing config created a backend endpoint: $(cat "$CASE_DIR/herdr.log")"
  test ! -s "$CASE_DIR/tmux-calls.log" || fail "a missing config reached tmux: $(cat "$CASE_DIR/tmux-calls.log")"
  fm_assert_no_cloud_reach "a missing controller config reached a worker provider"

  out=$(env -u FM_WORKER_PROVIDER_COMMAND FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-worker-lifecycle.sh" resume \
      --task "$id" --task-generation gen-missing \
      --repository-binding "$(printf '%064x' 9)" \
      --confirm-resume --confirm-subscription "$SUB" 2>&1)
  status=$?
  expect_code 1 "$status" "a primary recovery with no durable config should fail: $out"
  assert_contains "$out" "private config is missing" \
    "the primary recovery route did not autoload and reject its missing durable source: $out"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" \
    "a missing recovery config still wrote controller state"
  fm_assert_no_cloud_reach "a missing recovery config reached a worker provider"

  write_azure_controller_config "$HOME_DIR/config/azure-controller.env"
  printf 'FM_AZURE_CLIENT_SECRET=must-never-be-allowlisted\n' >> "$HOME_DIR/config/azure-controller.env"
  out=$(FM_SPAWN_CLOUD=azure \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a controller config with a non-allowlisted name should fail: $out"
  assert_contains "$out" "names non-allowlisted FM_AZURE_CLIENT_SECRET" \
    "the invalid config refusal did not name the allowlist boundary: $out"
  assert_not_contains "$out" "must-never-be-allowlisted" "the invalid config refusal printed its value: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "an invalid config still wrote task metadata"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" "an invalid config still wrote controller state"
  test -z "$(find "$HOME_DIR/treehouse-pools" -mindepth 1 -print -quit 2>/dev/null)" \
    || fail "an invalid config mutated the Treehouse pool"
  test ! -s "$CASE_DIR/herdr.log" || fail "an invalid config created a backend endpoint: $(cat "$CASE_DIR/herdr.log")"
  fm_assert_no_cloud_reach "an invalid controller config reached a worker provider"

  write_azure_controller_config "$HOME_DIR/config/azure-controller.env" not-a-private-uuid
  out=$(FM_SPAWN_CLOUD=azure \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a semantically invalid controller identity should fail early: $out"
  assert_contains "$out" "elastic worker controller values are invalid" \
    "the semantic config refusal did not name controller validation: $out"
  assert_not_contains "$out" "not-a-private-uuid" \
    "semantic validation printed the private invalid value: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a semantically invalid config still wrote task metadata"
  assert_absent "$HOME_DIR/state/azure-workers/controller.json" \
    "a semantically invalid config still wrote controller state"

  write_azure_controller_config "$HOME_DIR/config/azure-controller.env"
  chmod 644 "$HOME_DIR/config/azure-controller.env"
  out=$(FM_SPAWN_CLOUD=azure \
    run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a non-private controller source should fail: $out"
  assert_contains "$out" "must have no group/world permissions (use chmod 600)" \
    "the permissions refusal did not explain the private-file requirement: $out"
  assert_absent "$HOME_DIR/state/$id.meta" "a non-private config still wrote task metadata"
  fm_assert_no_cloud_reach "a non-private controller config reached a worker provider"

  help=$($SPAWN --help)
  assert_contains "$help" "config/azure-controller.env" \
    "fm-spawn help does not point to the durable Azure controller source: $help"
  pass "missing and invalid durable controller config refuse before worktree, backend, or cloud mutation"
}

test_the_pool_is_never_staged_in_the_request_to_narrow_window() {
  local record id out status
  id=cloud-window-c15
  record=$(make_cloud_case narrow-window "$id")
  read_cloud_case "$record"
  # THE WINDOW: the request-private snapshot exists and the tracking monitor
  # pane is already polling, but spawn has not staged the task-private copy.
  # The spawn is killed exactly there. If the pooled auth.json were staged
  # before selection (as it used to be), every signed-in account would be
  # sitting in a directory the monitor is willing to dispatch as --account-dir.
  # Written to a FILE, never captured through a command substitution. The spawn
  # is SIGKILLed here, and a command substitution would keep blocking on the
  # pipe until every surviving descendant (the tracking pane among them) closed
  # its copy - a hang that reads as a silent suite death rather than a failure.
  FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_TEST_CLOUD_ABORT_AFTER_REQUEST=1 \
    run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" \
    > "$CASE_DIR/window-spawn.log" 2>&1 </dev/null
  status=$?
  out=$(cat "$CASE_DIR/window-spawn.log" 2>/dev/null || true)
  test "$status" -ne 0 || fail "the spawn was supposed to die inside the window: $out"
  python3 - "$HOME_DIR/state/azure-workers/controller.json" "$HOME_DIR/state/$id.cloud-account" "$id" \
    "$CASE_DIR/pi-agent-home/auth.json" <<'PY2' || fail "the pooled credential reached the window"
import json
import pathlib
import sys

controller, account_dir, task, pool_path = sys.argv[1:]
state = json.load(open(controller, encoding="utf-8"))
live = [item for item in state["queue"].values()
        if item.get("task") == task and item.get("status") != "complete"]
# The queue-owned projection is durable, so the window is real and not skipped.
assert live, "no durable projection owner existed, so this never entered the window"
pool = json.load(open(pool_path, encoding="utf-8"))
assert len(pool) > 1, sorted(pool)
staged = pathlib.Path(account_dir) / "auth.json"
if staged.exists():
    parsed = json.load(open(staged, encoding="utf-8"))
    assert isinstance(parsed, dict) and len(parsed) == 1, (
        "the pooled credential was staged inside the window", sorted(parsed))
print("# window state: projection durable, staged slots = {}".format(
    sorted(json.load(open(staged, encoding="utf-8"))) if staged.exists() else "no auth.json at all"))
PY2
  pass "the pooled credential is never staged between private projection and task staging"
}

test_a_spawn_that_cannot_stage_its_snapshot_removes_projection() {
  local record id out status
  id=cloud-bindfail-c14
  record=$(make_cloud_case bind-failure "$id")
  read_cloud_case "$record"
  # A queued request owns one private profile projection.  If task staging
  # fails, withdraw must remove that exact projection without affecting the
  # reusable canonical profile or another assignment.
  out=$(FM_ACCOUNT_DIRECTORY_TEST_LAB=firstmate-account-directory-test-lab-v1 \
    FM_TEST_CLOUD_ACCOUNT_BIND_FAIL=1 \
    run_cloud_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a spawn that cannot stage its snapshot should fail: $out"
  assert_contains "$out" "could not stage its provider-account snapshot" \
    "the failure did not name the snapshot staging step: $out"
  assert_contains "$out" "removed the provider-account projection for $id" \
    "the spawn did not remove its assignment-private projection: $out"
  python3 - "$HOME_DIR/state/azure-workers/controller.json" "$id" <<'PY' \
    || fail "the unbindable placement kept holding its provider account"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {"queue": {}}
live = [item for item in state.get("queue", {}).values()
        if item.get("status") != "complete"]
assert not [item for item in live if item.get("task") == sys.argv[2]], live
# Nothing else holds an account either, so the whole pool is free again.
assert not [item for item in live if item.get("account_profile")], live
PY
  pass "a spawn staging failure removes only its assignment-private provider projection"
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

# The names spawn_cloud_persist_convergence_artifacts writes into
# state/<id>.cloud-env from paths OTHER than the SPAWN_CLOUD_ENV_ALLOWLIST loop.
# This list is the ONLY thing that excuses a name from the equality assertion
# below, and it is spelled out here rather than falling out of a filter so that
# adding an export somewhere else in that block is a visible decision instead of
# a silent exemption. The compartment block (FM_SECONDMATE_*) is listed even
# though a crewmate spawn never writes it, so the contract is stated once for
# both lanes rather than depending on which lane a test happens to drive.
CLOUD_ENV_NON_ALLOWLIST_EXPORTS='FM_SPAWN_CLOUD_WALL_SECONDS FM_SPAWN_CLOUD_RETURN_KIND FM_WORKER_PROVIDER_COMMAND FM_SECONDMATE_LEG_SECONDS FM_SECONDMATE_POLL_SECONDS FM_SECONDMATE_IDLE_SECONDS FM_SECONDMATE_TTL_HOURS FM_SECONDMATE_CHILD_PROJECT'

# A shape-valid value for one contract name. The SHAPES are what the readers
# accept (a phase enum, a bounded integer, a directory); the NAMES they are
# keyed off are pattern suffixes, never the specific variable this defect was
# reported as. A future contract name whose shape none of these fit fails the
# spawn below, which is red for a true reason and says so.
cloud_env_contract_sentinel() {  # <name>
  case $1 in
    # Mirrors of the values the rest of this suite's cloud lane runs with, so
    # the fixture provider and the controller still agree with each other.
    FM_AZURE_TENANT_ID) printf '33333333-3333-4333-8333-333333333333' ;;
    FM_AZURE_SUBSCRIPTION_ID) printf '%s' "$SUB" ;;
    FM_AZURE_ADMIN_EMAIL) printf 'contract@example.invalid' ;;
    FM_AZURE_ADMIN_USERNAME) printf 'fmcontract' ;;
    FM_AZURE_ADMIN_SSH_PUBLIC_KEY) printf 'ssh-ed25519 AAAAC3NzaFixture contract@example.invalid' ;;
    FM_AZURE_RUNNER_OPERATOR_OBJECT_ID) printf '44444444-4444-4444-8444-444444444444' ;;
    FM_AZURE_DEPLOYMENT_GENERATION) printf 'dep-one' ;;
    FM_AZURE_OWNER_TAG) printf 'owner' ;;
    FM_AZURE_NAMING_PREFIX) printf 'fmtest' ;;
    FM_AZURE_STORAGE_NAME) printf 'fmteststorage001' ;;
    FM_AZURE_KEY_VAULT_NAME) printf 'fmtest-key-vault-001' ;;
    FM_AZURE_BUDGET_START_DATE) printf '2026-01-01' ;;
    FM_AZURE_OPERATOR_DATA_PLANE_IP) printf '203.0.113.10' ;;
    FM_AZURE_RUNNER_VALIDATION_SKU) printf 'Standard_D4as_v6' ;;
    FM_AZURE_VM_FAMILY) printf 'Dasv6' ;;
    FM_AZURE_WORKER_SLOTS) printf '1' ;;
    FM_AZURE_WORKER_SKUS) printf 'Standard_D4as_v6' ;;
    FM_AZURE_WORKER_STATE_DIR) printf '%s' "$HOME_DIR/state/azure-workers" ;;
    *_STATE_DIR) printf '%s' "$CASE_DIR/contract-state" ;;
    *_POLICY_PHASE) printf 'commissioning' ;;
    *_WORKER_MAX) printf '16' ;;
    *_SECONDMATE_MAX) printf '2' ;;
    *_BOUND_OVERRIDE) date -u +%Y-%m-%d ;;
    *_ALLOW_UNTRAINED_FORECAST|*_PROTECT_DURABLE_STATE|*_WARM_IDLE) printf '0' ;;
    # The commissioning ceiling is not a free knob: admission refuses any
    # value other than the reviewed one.
    *_CEILING_USD) printf '1500' ;;
    *_HOURS) printf '24' ;;
    *_SECONDS|*_USD|*_THRESHOLD) printf '900' ;;
    *) printf 'fmcontract-%s' "$1" ;;
  esac
}

test_persisted_cloud_env_matches_the_deployment_read_set_exactly() {
  # THE CLOSED-PANE CONTRACT, asserted as an EFFECT, in BOTH directions.
  #
  # state/<id>.cloud-env is the ONLY channel between the operator's shell and
  # the compartment/crewmate monitors, whose Herdr panes inherit nothing. What
  # that file must carry is decided on the far side, by the code that reads it
  # when a lifecycle call reaches the provider and the provider shells out to
  # bin/fm-azure-pilot.sh for the deployment. This test derives that read set
  # from those readers (bin/fm-cloud-env-contract.py) and asserts the file the
  # spawn ACTUALLY WROTE equals it.
  #
  # EQUALITY, not containment, and that is the whole point of the second half.
  # A contract name the file cannot carry is an outage - that is the defect this
  # test exists for. But an EXTRA name the file carries and no reader wants is
  # the opposite failure and the more dangerous one: SPAWN_CLOUD_ENV_ALLOWLIST
  # is what keeps a secret-bearing FM_AZURE_* off disk, and a containment-only
  # assertion would let anyone widen it to FM_AZURE_GITHUB_TOKEN_FILE or the
  # FM_AZURE_VALIDATION_*_KEY_FILE pair and stay green. So the probe environment
  # is deliberately WIDER than the contract - it is the contract UNION every
  # name the allowlist currently spells - and any probe name that survives into
  # the file without a reader asking for it fails here.
  #
  # THE COMPARISON IS SCOPED TO THE FILE, NOT TO THE PROBE. An earlier revision
  # intersected the file's contents with the probe before comparing, which put
  # every name written by a path OTHER than the allowlist loop outside the
  # assertion entirely - a one-line `printf export FM_AZURE_CLIENT_SECRET`
  # added anywhere else in spawn_cloud_persist_convergence_artifacts stayed
  # green. The persist block really does have such paths (the wall, the
  # provider-command override, the compartment leg block), so the exemption is
  # spelled out by name in CLOUD_ENV_NON_ALLOWLIST_EXPORTS below and every
  # other name in the file, whatever wrote it, is compared. A silent
  # consequence of an intersect is how the last one hid.
  #
  # Deliberately not a grep for any one variable: a name added to a reader and
  # not to the allowlist goes red here without this test ever having heard of
  # it. That is the failure that had to reach a live Azure run before, because
  # every provider in this suite is a fixture that never shells out to the
  # pilot at all.
  local record id out env_file required declared probe count name want got
  local missing extra persisted mismatched
  id=cloud-env-c30
  record=$(make_cloud_case env-contract "$id")
  read_cloud_case "$record"
  # stderr is captured separately, not folded in: every ContractError the
  # derivation raises goes to stderr, so folding it into $required would put the
  # refusal text into the name list, and dropping it leaves the failure reading
  # "could not be derived:" with nothing after the colon. A sealed re-drive of
  # the async-def hoist produced exactly that empty message.
  local contract_err="$CASE_DIR/contract.err"
  required=$("$ROOT/bin/fm-cloud-env-contract.py" 2>"$contract_err") \
    || fail "the cloud-env contract could not be derived: $(cat "$contract_err" 2>/dev/null)"
  count=$(printf '%s\n' "$required" | grep -c '^FM_')
  # Vacuity guard: a derivation that silently matched nothing would make every
  # assertion below pass while proving nothing at all.
  [ "$count" -ge 12 ] || fail "the cloud-env contract derived only $count names; the derivation is broken"
  # What the allowlist SPELLS, read only to widen the probe environment. It is
  # never asserted against directly - the assertions below are all about the
  # file the spawn wrote - but without it an extra allowlist name would simply
  # be unset at spawn time and leave no trace to catch.
  declared=$(sed -n "s/^SPAWN_CLOUD_ENV_ALLOWLIST='\(.*\)'$/\1/p" "$ROOT/bin/fm-spawn.sh" | tr ' ' '\n' | grep '^FM_')
  count=$(printf '%s\n' "$declared" | grep -c '^FM_')
  # Second vacuity guard: a failed extraction would silently narrow the probe
  # back to the contract and disarm the extra-name half of this test.
  [ "$count" -ge 12 ] || fail "only $count allowlist names could be read from bin/fm-spawn.sh; the probe environment would be too narrow to detect an extra name"
  # Every name the persist block emits as a LITERAL `export NAME=` line, from
  # any path, not just the allowlist loop. Also probe-widening only, never
  # asserted against: a rogue export is written only when its variable is set,
  # so without setting it the rogue line is inert and the file never shows it.
  # That inertness is exactly what let a hand-added
  # `printf 'export FM_AZURE_CLIENT_SECRET=%q\n'` pass review round two.
  local emitted
  # grep -o, not an anchored sed: these printfs appear after `||` and inside
  # case arms, so a line-start anchor sees one of the three and the guard below
  # is what caught that. The `%s` form (the allowlist loop itself) has no
  # literal name and is deliberately not matched.
  emitted=$(grep -o "printf 'export [A-Za-z_][A-Za-z0-9_]*=" "$ROOT/bin/fm-spawn.sh" \
    | sed "s/^printf 'export //; s/=$//" | sort -u)
  count=$(printf '%s\n' "$emitted" | grep -c '^[A-Za-z_]')
  # Third vacuity guard, same reason as the other two.
  [ "$count" -ge 2 ] || fail "only $count literal export names could be read from bin/fm-spawn.sh; the probe environment would miss a non-allowlist export path"
  probe=$(printf '%s\n%s\n%s\n' "$required" "$declared" "$emitted" | grep '^[A-Za-z_]' | sort -u)
  out=$(
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      export "$name=$(cloud_env_contract_sentinel "$name")"
    done <<PROBE
$probe
PROBE
    FM_SPAWN_CLOUD=azure \
      FM_TEST_ACTUAL_USD=2000 \
      FM_WORKER_PROVIDER_COMMAND="python3 $CASE_DIR/provider.py" \
      FIXTURE_STATE="$CASE_DIR/provider-state.json" \
      run_spawn "$CASE_DIR" "$HOME_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR"
  )
  expect_code 0 $? "the contract cloud spawn should succeed: $out"
  env_file="$HOME_DIR/state/$id.cloud-env"
  assert_present "$env_file" "the cloud spawn persisted no environment for the closed pane"
  # EVERY name the file carries, minus the explicitly named non-allowlist
  # exports. Nothing is filtered by the probe here, so a name written by any
  # other path in the persist block - allowlisted or not, FM_AZURE_ or not -
  # lands in the comparison and has to be accounted for.
  persisted=$(sed -n 's/^export \([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$env_file" | sort -u \
    | comm -23 - <(printf '%s\n' "$CLOUD_ENV_NON_ALLOWLIST_EXPORTS" | tr ' ' '\n' | grep . | sort -u))
  missing=$(comm -23 <(printf '%s\n' "$required" | sort -u) <(printf '%s\n' "$persisted") | tr '\n' ' ')
  extra=$(comm -13 <(printf '%s\n' "$required" | sort -u) <(printf '%s\n' "$persisted") | tr '\n' ' ')
  missing=${missing% }
  extra=${extra% }
  [ -z "$missing" ] || fail "the persisted cloud-env cannot reach the deployment path: the closed pane never sees $missing (regenerate SPAWN_CLOUD_ENV_ALLOWLIST in bin/fm-spawn.sh with bin/fm-cloud-env-contract.py --allowlist; if a name is here only because some reader MENTIONS it and its value would be a credential, the answer is an entry in SECRET_BEARING_EXCLUSIONS in bin/fm-cloud-env-contract.py, NOT a new allowlist entry)"
  [ -z "$extra" ] || fail "the persisted cloud-env writes names no reader on the deployment path asks for: $extra (SPAWN_CLOUD_ENV_ALLOWLIST is what keeps a secret-bearing FM_AZURE_* off disk; drop them, or add the reader that needs them, or record the judgment in SECRET_BEARING_EXCLUSIONS in bin/fm-cloud-env-contract.py. If one is a DELIBERATE non-allowlist export from another path in spawn_cloud_persist_convergence_artifacts, name it in CLOUD_ENV_NON_ALLOWLIST_EXPORTS in this file - deliberately, in the open, never by widening a filter)"
  mismatched=
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    want=$(cloud_env_contract_sentinel "$name")
    # Read it the way a monitor does: source the file in an environment
    # scrubbed to what a Herdr pane actually keeps. `env -u FM_*` is not a
    # thing, and unsetting by prefix here would leave the operator's own
    # exports leaking in and hide exactly this defect.
    # The inner script must stay unexpanded: $1/$2 are the scrubbed shell's own
    # arguments, and the indirect read is what proves the name is reachable.
    # shellcheck disable=SC2016
    got=$(env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG="${LANG:-C}" \
      bash -c '. "$1" >/dev/null 2>&1 || true; value=$2; printf "%s" "${!value-}"' \
      _ "$env_file" "$name")
    [ "$got" = "$want" ] || mismatched="$mismatched $name"
  done <<CONTRACT
$required
CONTRACT
  [ -z "$mismatched" ] || fail "the persisted cloud-env does not round-trip its value for$mismatched"
  pass "the persisted cloud-env equals the deployment read set, value-exact through a closed environment, with no name the readers never asked for"
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
  # An unlanded outcome bundle from the previous generation is the last copy of
  # a crewmate's commits once the guest is gone, so the sweep must preserve it
  # rather than delete it with the transport state.
  mkdir -p "$HOME_DIR/state/$id.cloud-outcome"
  printf 'previous generation commits\n' > "$HOME_DIR/state/$id.cloud-outcome/outcome.bundle"
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
  local preserved
  preserved=$(find "$HOME_DIR/state" -maxdepth 1 -name "$id.cloud-outcome.superseded-*" | head -1)
  test -n "$preserved" \
    || fail "the re-spawn destroyed the previous generation's unlanded outcome bundle"
  assert_present "$preserved/outcome.bundle" "the preserved directory holds no bundle"
  assert_grep 'previous generation commits' "$preserved/outcome.bundle" \
    "the preserved bundle is not the previous generation's bytes"
  assert_absent "$HOME_DIR/state/$id.cloud-outcome/outcome.bundle" \
    "a stale bundle stayed where the new generation's monitor would land it"
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
  # This direct primary recovery/convergence entry has no explicit Azure
  # identity. The lifecycle wrapper must load the same durable home config.
  out=$(FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
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
  # This case owns queued-dispatch convergence, not the return finalizer. The
  # latter is driven end to end in fm-cloud-result.test.sh; keep this monitor
  # on the legacy no-return fixture so it exits without invoking release.
  grep -v '^export FM_SPAWN_CLOUD_RETURN_KIND=' "$HOME_DIR/state/$id.cloud-env" \
    > "$HOME_DIR/state/$id.cloud-env.tmp"
  mv "$HOME_DIR/state/$id.cloud-env.tmp" "$HOME_DIR/state/$id.cloud-env"
  # A later durable edit must not retarget an already-dispatched task. The
  # monitor exports its persisted values before the lifecycle wrapper reloads
  # the home source, so task-specific explicit precedence keeps this on SUB.
  write_azure_controller_config "$HOME_DIR/config/azure-controller.env" "$OTHER_SUB"
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

stage_landing_case() {
  # Build a REAL round trip: a source worktree, a clone that commits like a
  # crewmate would, and the outcome bundle the supervisor would have written.
  local id=$1 src=$2 outcome=$3 base
  fm_git_init_commit "$src"
  base=$(git -C "$src" rev-parse HEAD)
  git clone --quiet "$src" "$CASE_DIR/worker-copy"
  fm_git_identity "$CASE_DIR/worker-copy"
  printf 'crewmate work\n' > "$CASE_DIR/worker-copy/outcome.txt"
  git -C "$CASE_DIR/worker-copy" add -A
  git -C "$CASE_DIR/worker-copy" commit --quiet -m "crewmate work"
  mkdir -p "$outcome"
  git -C "$CASE_DIR/worker-copy" bundle create "$outcome/outcome.bundle" "$base..HEAD" >/dev/null 2>&1
  printf '%s\n' "$src" > "$HOME_DIR/state/$id.cloud-worktree"
  python3 - "$HOME_DIR/state/$id.worker-result.json" "$base" <<'PY'
import json
import sys

path, base = sys.argv[1:]
json.dump({
    "schema": "fm.worker-execution-result/v1",
    "task": "task", "task_generation": "gen-1", "assignment_generation": "asg-00000001",
    "cloud_instance_id": "vm", "repository_binding": "b" * 64, "repository_generation": base,
    "request_digest": "d" * 64, "result_digest": "e" * 64, "exit_code": 0, "timed_out": False,
    "outcome_present": True, "outcome_error": "", "outcome_commits": 1,
    "outcome_sha256": "f" * 64, "outcome_bytes": 1,
}, open(path, "w"), sort_keys=True, separators=(",", ":"))
PY
  printf '%s\n' "$base"
}

test_monitor_lands_the_outcome_bundle() {
  # Landing v1: when the digest-verified outcome bundle is home and the leased
  # worktree still sits on the dispatched generation, the monitor really
  # fast-forwards it, so the ordinary local landing flow has the work.
  local record id src base
  id=cloud-land-c14
  record=$(make_cloud_case landing-lane "$id")
  read_cloud_case "$record"
  src="$CASE_DIR/leased"
  base=$(stage_landing_case "$id" "$src" "$HOME_DIR/state/$id.cloud-outcome")
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/monitor.log" 2>&1
  expect_code 0 $? "the monitor should exit cleanly on a landed result: $(cat "$CASE_DIR/monitor.log")"
  assert_grep 'landed 1 commit' "$CASE_DIR/monitor.log" "the monitor did not report the landing"
  assert_present "$src/outcome.txt" "the crewmate's commit did not reach the leased worktree"
  test "$(git -C "$src" rev-parse HEAD)" != "$base" \
    || fail "the leased worktree was never fast-forwarded"
  pass "the monitor lands a verified outcome bundle into the leased worktree"
}

test_monitor_reports_an_already_landed_outcome() {
  # Re-opening a tracking pane over a landed result must not report the work
  # as diverged and send the operator hunting for a landing that happened.
  local record id src
  id=cloud-land-c16
  record=$(make_cloud_case landing-again-lane "$id")
  read_cloud_case "$record"
  src="$CASE_DIR/leased"
  stage_landing_case "$id" "$src" "$HOME_DIR/state/$id.cloud-outcome" >/dev/null
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/first.log" 2>&1
  assert_grep 'landed 1 commit' "$CASE_DIR/first.log" "the first run did not land the outcome"
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/second.log" 2>&1
  assert_grep 'already landed' "$CASE_DIR/second.log" \
    "a second pane reported an already-landed outcome as something else"
  assert_no_grep 'moved off' "$CASE_DIR/second.log" \
    "an already-landed outcome was reported as divergence"
  pass "a re-opened pane reports an already-landed outcome as landed"
}

test_monitor_reports_a_crewmate_that_never_committed() {
  # outcome_present=false with uncommitted changes is work that did not come
  # home; it must not read as a clean read-only task.
  local record id
  id=cloud-land-c17
  record=$(make_cloud_case landing-dirty-lane "$id")
  read_cloud_case "$record"
  python3 - "$HOME_DIR/state/$id.worker-result.json" <<'RESULT'
import json
import sys

json.dump({
    "schema": "fm.worker-execution-result/v1", "task": "t", "task_generation": "gen-1",
    "assignment_generation": "asg-00000001", "cloud_instance_id": "vm",
    "repository_binding": "b" * 64, "repository_generation": "r" * 40,
    "request_digest": "d" * 64, "result_digest": "e" * 64, "exit_code": 0,
    "timed_out": False, "outcome_present": False, "outcome_error": "",
    "outcome_commits": 0, "outcome_uncommitted_changes": True,
}, open(sys.argv[1], "w"), sort_keys=True, separators=(",", ":"))
RESULT
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/monitor.log" 2>&1
  assert_grep 'uncommitted changes' "$CASE_DIR/monitor.log" \
    "a crewmate that never committed was reported as having nothing to land"
  pass "a crewmate that edited without committing is reported, not silently dropped"
}

test_monitor_lands_despite_a_collection_error() {
  # A failure in one arm of the run (stream evidence, say) is reported, but it
  # must never throw away work the controller already downloaded and verified.
  local record id src base
  id=cloud-land-c18
  record=$(make_cloud_case landing-error-lane "$id")
  read_cloud_case "$record"
  src="$CASE_DIR/leased"
  base=$(stage_landing_case "$id" "$src" "$HOME_DIR/state/$id.cloud-outcome")
  python3 - "$HOME_DIR/state/$id.worker-result.json" <<'RESULT'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    result = json.load(handle)
result["outcome_error"] = "stream evidence: FileExistsError: /mnt/task/.fm-worker"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(result, handle, sort_keys=True, separators=(",", ":"))
RESULT
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/monitor.log" 2>&1
  assert_grep 'reported a failure during collection' "$CASE_DIR/monitor.log" \
    "the collection failure was not reported"
  assert_grep 'landed 1 commit' "$CASE_DIR/monitor.log" \
    "a verified bundle was discarded because another arm of the run failed"
  assert_present "$src/outcome.txt" "the crewmate's commit did not reach the leased worktree"
  pass "a collection error is reported without discarding a bundle that arrived"
}

test_monitor_keeps_the_outcome_when_the_worktree_moved() {
  # If the local side moved on, a silent fast-forward would be wrong: the
  # bundle is kept and the operator is told where it is.
  local record id src
  id=cloud-land-c15
  record=$(make_cloud_case landing-moved-lane "$id")
  read_cloud_case "$record"
  src="$CASE_DIR/leased"
  stage_landing_case "$id" "$src" "$HOME_DIR/state/$id.cloud-outcome" >/dev/null
  printf 'local divergence\n' > "$src/local.txt"
  git -C "$src" add -A
  git -C "$src" commit --quiet -m "local work after dispatch"
  FM_HOME="$HOME_DIR" FM_SPAWN_CLOUD_MONITOR_INTERVAL_SECONDS=1 \
    "$ROOT/bin/fm-spawn-cloud-monitor.sh" "$id" gen-1 > "$CASE_DIR/monitor.log" 2>&1
  expect_code 0 $? "the monitor should exit cleanly: $(cat "$CASE_DIR/monitor.log")"
  assert_grep 'kept at' "$CASE_DIR/monitor.log" "the monitor did not report where it kept the outcome"
  assert_absent "$src/outcome.txt" "the monitor landed onto a worktree that had moved"
  pass "the monitor refuses to land onto a worktree that moved off the dispatched generation"
}

make_child_case() {  # <name> <child-id> <parent-id> -> record
  # The compartment-child shape: a PRIMARY home that owns the ONE controller
  # document and the config, and a separate seeded SECONDMATE home that owns
  # this task's state, data and projects.
  local name=$1 id=$2 parent=$3 case_dir primary sub project worktree fakebin
  local foreign_project foreign_worktree
  case_dir="$TMP_ROOT/$name"
  primary="$case_dir/primary"
  sub="$case_dir/secondmate-home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  foreign_project="$case_dir/primary-project"
  foreign_worktree="$case_dir/primary-worktree"
  mkdir -p "$primary/data" "$primary/state" "$primary/config" \
    "$sub/data" "$sub/projects" "$sub/state" "$sub/treehouse-pools" \
    "$case_dir/codex-home" "$case_dir/pi-agent-home"
  chmod 755 "$case_dir"
  fm_spawn_cloud_write_pi_pool "$case_dir/pi-agent-home/auth.json"
  printf '%s\n' codex > "$primary/config/crew-harness"
  printf '%s\n' manual > "$primary/config/backlog-backend"
  write_azure_controller_config "$primary/config/azure-controller.env"
  fm_git_init_commit "$project"
  git -C "$project" worktree add --quiet --detach "$worktree"
  fm_git_init_commit "$foreign_project"
  git -C "$foreign_project" worktree add --quiet --detach "$foreign_worktree"
  touch "$sub/state/.last-watcher-beat"
  mkdir -p "$sub/data/$id"
  printf 'brief for %s\n' "$id" > "$sub/data/$id/brief.md"
  printf '# Backlog\n\n## In flight\n- [ ] %s - compartment child test (repo: project)\n\n## Queued\n\n## Done\n' \
    "$id" > "$sub/data/backlog.md"
  # The two independent primary-owned links in the authority chain: the marker
  # inside the home NAMES the secondmate, and the primary's own registry maps
  # that secondmate to exactly this directory.
  printf 'fixture home\n' > "$sub/AGENTS.md"
  mkdir -p "$sub/bin"
  printf '%s\n' "$parent" > "$sub/.fm-secondmate-home"
  printf '# secondmates\n\n- %s - the compartment (home: %s; scope: everything; projects: ; added 2026-08-20)\n' \
    "$parent" "$sub" > "$primary/data/secondmates.md"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  write_fixture_provider "$case_dir/provider.py"
  : > "$case_dir/launch.log"
  : > "$case_dir/tmux-calls.log"
  : > "$case_dir/herdr.log"
  printf '{"next":1,"workspaces":[],"tabs":[],"agent_status":{}}\n' > "$case_dir/herdr-state.json"
  printf '%s\n' "$case_dir|$primary|$sub|$project|$worktree|$fakebin"
}

read_child_case() {
  IFS='|' read -r CASE_DIR PRIMARY_DIR SUB_DIR PROJECT_DIR WORKTREE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

fixture_git_common_dir() {  # <repository>
  local repository=$1 common
  common=$(git -C "$repository" rev-parse --git-common-dir) || return 1
  case "$common" in
    /*) : ;;
    *) common="$repository/$common" ;;
  esac
  (cd "$common" 2>/dev/null && pwd -P)
}

run_child_spawn() {  # <case> <primary> <sub> <worktree> <fakebin> [extra env assignments...] -- args
  # Deliberately sets NO FM_STATE_OVERRIDE/FM_DATA_OVERRIDE/FM_PROJECTS_OVERRIDE:
  # the split derives them from the task home, and fm-spawn refuses the
  # combination outright. FM_HOME stays the primary, because FM_HOME is what
  # names the money document.
  local case_dir=$1 primary=$2 sub=$3 worktree=$4 fakebin=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$primary" \
    FM_SPAWN_TASK_HOME="$sub" \
    FM_CONFIG_OVERRIDE="$primary/config" \
    FM_TREEHOUSE_ROOT="$sub/treehouse-pools" \
    FM_CHECKOUT_REFRESH_STATE_BASE="$case_dir/checkout-refresh-state" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$worktree" TMUX="fake,1,0" \
    FM_FAKE_TREEHOUSE_WORKTREE="$worktree" \
    FM_FAKE_TREEHOUSE_TASK_HOME="$sub" \
    FM_FAKE_TREEHOUSE_FOREIGN_WORKTREE="$case_dir/primary-worktree" \
    FM_TEST_LAUNCH_LOG="$case_dir/launch.log" \
    FM_TEST_TMUX_CALLS="$case_dir/tmux-calls.log" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HERDR_LOG="$case_dir/herdr.log" \
    FM_FAKE_HERDR_STATE="$case_dir/herdr-state.json" \
    CODEX_HOME="$case_dir/codex-home" \
    PI_CODING_AGENT_DIR="$case_dir/pi-agent-home" \
    FM_SPAWN_CLOUD=azure-only \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    PATH="$fakebin:$PATH" "$SPAWN" "$@" 2>&1
}

stand_up_compartment() {  # <case> <primary> <parent-id> <parent-generation>
  local case_dir=$1 primary=$2 parent=$3 generation=$4
  FM_HOME="$primary" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1 \
    "$ROOT/bin/fm-worker-lifecycle.sh" request \
      --task "$parent" --task-generation "$generation" \
      --home-binding "$(printf '%064x' 21)" --account-binding "$(printf '%064x' 22)" \
      --worktree-binding "$(printf '%064x' 23)" --repository-binding "$(printf '%064x' 24)" \
      --repository-generation repo-parent --owner-kind primary --role secondmate --eligible \
    || return 1
  FM_HOME="$primary" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    FM_WORKER_TEST_ALLOW_ASSERTED_BINDINGS=1 \
    "$ROOT/bin/fm-worker-lifecycle.sh" reconcile --apply --confirm-subscription "$SUB" >/dev/null
}

test_compartment_child_spawn_splits_the_task_home_from_the_money_document() {
  # The headline R2/R3 requirement, end to end through the real spawn: a
  # secondmate running in Azure obtains a crewmate. The child's task lives in
  # the SECONDMATE's home; the request is admitted into the PRIMARY's one
  # controller document; no second document is ever created.
  local record id parent out status meta controller target endpoint_state source_config source_dir
  id=child-c1
  parent=smc-e2e
  record=$(make_child_case child-lane "$id" "$parent")
  read_child_case "$record"
  stand_up_compartment "$CASE_DIR" "$PRIMARY_DIR" "$parent" gen-parent \
    || fail "the parent compartment could not be stood up in the primary's controller"
  controller="$PRIMARY_DIR/state/azure-workers/controller.json"
  assert_grep '"role":"secondmate"' "$controller" "the parent compartment is not a secondmate record"
  out=$(FM_SPAWN_PARENT_TASK="$parent" FM_SPAWN_PARENT_TASK_GENERATION=gen-parent \
    run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$SUB_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a compartment child spawn should succeed: $out"
  assert_contains "$out" "spawned $id" "the compartment child spawn did not complete: $out"
  assert_contains "$out" "placement=azure" "the compartment child spawn never reached cloud placement: $out"
  # The task's own files live in the SECONDMATE's home.
  meta="$SUB_DIR/state/$id.meta"
  assert_present "$meta" "the child's task metadata did not land in the secondmate home"
  assert_absent "$PRIMARY_DIR/state/$id.meta" "the child's task metadata landed in the primary home"
  assert_grep 'placement=azure' "$meta" "the child spawn did not record placement=azure"
  source_config=$(find "$SUB_DIR/state/treehouse-sources" -name treehouse.toml -type f -print -quit 2>/dev/null)
  [ -n "$source_config" ] || fail "the compartment child did not create its managed Treehouse source under the task home"
  assert_absent "$PRIMARY_DIR/state/treehouse-sources" \
    "the compartment child created its managed Treehouse source under the primary money home"
  assert_grep "$SUB_DIR" "$source_config" \
    "the compartment child's managed source does not select the task-home Treehouse root"
  source_dir=$(dirname "$source_config")
  [ "$(fixture_git_common_dir "$source_dir")" = \
    "$(fixture_git_common_dir "$PROJECT_DIR")" ] || fail \
    "the managed Treehouse source and compartment project have different Git common identities"
  [ "$(fixture_git_common_dir "$WORKTREE_DIR")" = \
    "$(fixture_git_common_dir "$PROJECT_DIR")" ] || fail \
    "the leased Treehouse worktree and compartment project have different Git common identities"
  # The money document is the primary's, and there is exactly one of them.
  assert_present "$controller" "the primary's controller document is gone"
  assert_absent "$SUB_DIR/state/azure-workers/controller.json" \
    "the compartment child lane created a SECOND controller document under the secondmate home"
  python3 - "$controller" "$id" "$parent" "$SUB_DIR" "$PRIMARY_DIR" <<'PY' \
    || fail "the admitted child is not bound to the secondmate home under the primary's document"
import hashlib
import json
import sys
from pathlib import Path

controller, task, parent, sub, primary = sys.argv[1:]
state = json.loads(Path(controller).read_text())
items = [item for item in state["queue"].values() if item.get("task") == task]
assert len(items) == 1, state["queue"]
item = items[0]
assert item["owner_kind"] == "secondmate", item
assert item["role"] == "author", item
assert item["parent_task"] == parent and item["parent_task_generation"] == "gen-parent", item
sub_binding = hashlib.sha256(str(Path(sub).resolve()).encode()).hexdigest()
primary_binding = hashlib.sha256(str(Path(primary).resolve()).encode()).hexdigest()
assert item["home_binding"] == sub_binding, (item["home_binding"], sub_binding)
assert state["home_binding"] == primary_binding, (state["home_binding"], primary_binding)
parent_item = state["queue"]["{}@{}".format(parent, "gen-parent")]
worker = state["workers"][str(parent_item["slot"])]
assert int(worker.get("children_total", 0)) == 1, worker
PY
  # The tracking endpoint belongs to the same task home as the metadata, even
  # though the primary home owns the one money document. Preserve the workspace
  # while removing the exact pane: the ordinary release authority probes with
  # FM_HOME=$SUB_DIR and must then receive the structural `absent` verdict. If
  # spawn instead labeled the workspace from the primary home, Herdr correctly
  # answers `unknown` here because the recorded workspace id still exists under
  # the foreign `firstmate` label; that mismatch strands the worker forever.
  target=$(sed -n 's/^window=//p' "$meta")
  [ -n "$target" ] || fail "the compartment child metadata has no tracking endpoint target"
  python3 - "$CASE_DIR/herdr-state.json" "$target" <<'PY' \
    || fail "the fixture could not remove the exact tracking pane"
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
pane = sys.argv[2].split(":", 1)[1]
state = json.loads(path.read_text(encoding="utf-8"))
before = list(state["tabs"])
state["tabs"] = [tab for tab in before if tab["pane_id"] != pane]
assert len(before) - len(state["tabs"]) == 1, (pane, before)
assert state["workspaces"], state
path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
PY
  endpoint_state=$(unset FM_ROOT_OVERRIDE; \
    FM_HOME="$SUB_DIR" FM_ROOT="$SUB_DIR" \
    FM_BACKEND_HERDR_TEST_LAB=firstmate-herdr-test-lab-v1 \
    FM_HERDR_LOG="$CASE_DIR/herdr.log" FM_FAKE_HERDR_STATE="$CASE_DIR/herdr-state.json" \
    PATH="$FAKEBIN_DIR:$PATH" bash -c \
      '. "$1"; fm_backend_target_state herdr "$2" "$3"' \
      _ "$ROOT/bin/fm-backend.sh" "$target" "fm-$id")
  [ "$endpoint_state" = absent ] || fail \
    "the secondmate-home endpoint authority returned $endpoint_state after exact pane absence"
  pass "a compartment child uses its task-home workspace and the primary's one controller"
}

test_task_home_refusals_are_exact() {
  # Every way the split can be asked for wrongly refuses before anything is
  # written: a relative path, a directory that is not a seeded secondmate home,
  # and the override combination that would silently re-point the task files.
  local record id parent out status
  id=child-c2
  parent=smc-refuse
  record=$(make_child_case child-refusals "$id" "$parent")
  read_child_case "$record"
  out=$(FM_SPAWN_TASK_HOME=relative/path run_child_spawn \
    "$CASE_DIR" "$PRIMARY_DIR" "relative/path" "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a relative FM_SPAWN_TASK_HOME should refuse: $out"
  assert_contains "$out" "FM_SPAWN_TASK_HOME must be an absolute path" "$out"
  out=$(run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$CASE_DIR/nowhere" "$WORKTREE_DIR" \
    "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a missing FM_SPAWN_TASK_HOME should refuse: $out"
  assert_contains "$out" "is not an existing directory" "$out"
  out=$(run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$PROJECT_DIR" "$WORKTREE_DIR" \
    "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "an unmarked FM_SPAWN_TASK_HOME should refuse: $out"
  assert_contains "$out" "is not a seeded secondmate home" "$out"
  out=$(FM_STATE_OVERRIDE="$SUB_DIR/state" run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$SUB_DIR" \
    "$WORKTREE_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "FM_SPAWN_TASK_HOME with a state override should refuse: $out"
  assert_contains "$out" "cannot be combined with FM_STATE_OVERRIDE" "$out"
  assert_absent "$SUB_DIR/state/$id.meta" "a refused task-home spawn still wrote task metadata"
  assert_absent "$PRIMARY_DIR/state/azure-workers/controller.json" \
    "a refused task-home spawn still reached the controller"
  pass "every unsafe task home refuses before the spawn writes anything"
}

run_child_lifecycle() {  # <case> <fakebin> <primary> <lifecycle args...>
  # The controller document is the PRIMARY's, so every lifecycle command for a
  # compartment child runs with FM_HOME on the primary. That is exactly the
  # condition under which a primary-resolved remover misses the credential.
  local case_dir=$1 fakebin=$2 primary=$3
  shift 3
  # The fakebin goes first on PATH like every other helper here. Nothing in
  # this lane shells a stubbed tool today; the moment one does, a helper that
  # omitted this would reach the real one.
  PATH="$fakebin:$PATH" \
  FM_HOME="$primary" \
    FM_AZURE_SUBSCRIPTION_ID="$SUB" \
    FM_AZURE_DEPLOYMENT_GENERATION=dep-one \
    FM_AZURE_OWNER_TAG=owner \
    FM_AZURE_NAMING_PREFIX=fmtest \
    FM_AZURE_WORKER_IDLE_COOLDOWN_SECONDS=0 \
    FM_WORKER_PROVIDER_COMMAND="python3 $case_dir/provider.py" \
    FIXTURE_STATE="$case_dir/provider-state.json" \
    "$ROOT/bin/fm-worker-lifecycle.sh" "$@" 2>&1
}

child_queue_generation() {  # <controller> <task>
  python3 - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

controller, task = sys.argv[1:]
state = json.loads(Path(controller).read_text())
for item in state.get("queue", {}).values():
    if item.get("task") == task:
        print(item["task_generation"])
        break
PY
}

raise_fixture_actual_cost() {  # <case> <usd>
  # The fixture provider seeds its cost metrics on the FIRST call and then
  # reloads them from its own state file, so FM_TEST_ACTUAL_USD on a later
  # command changes nothing. Rewriting the persisted metric is what actually
  # steers a subsequent admission past policy, which is how a compartment
  # child is held in `queued` - withdraw's one legal input.
  python3 - "$1/provider-state.json" "$2" <<'PY'
import json
import sys
from pathlib import Path

path, usd = Path(sys.argv[1]), float(sys.argv[2])
state = json.loads(path.read_text())
state["metrics"]["actual_usd"] = usd
path.write_text(json.dumps(state))
PY
}

assert_fixture_provider_drove_the_lane() {  # <case>
  # Safety, not decoration: with an operator environment present the real
  # provider would be selected and a test believing it drives a fake would
  # create billable compute. The fixture provider records every call it
  # served, so this proves the lane ran against the fixture.
  local case_dir=$1
  assert_present "$case_dir/provider-state.json" \
    "the fixture provider never ran; this lane may have reached a real provider"
  assert_grep '"calls"' "$case_dir/provider-state.json" \
    "the fixture provider recorded no calls; this lane may have reached a real provider"
}

controller_task_state_dir() {  # <controller> <task> <fallback>
  python3 - "$1" "$2" "$3" <<'CTRL'
import json
import sys
from pathlib import Path

controller, task, fallback = sys.argv[1:]
state = json.loads(Path(controller).read_text())
for item in state.get("queue", {}).values():
    if item.get("task") == task:
        home = item.get("task_home")
        print("{}/state".format(home) if home else fallback)
        break
CTRL
}

test_compartment_child_staging_and_removal_resolve_the_same_home() {
  # THE STRUCTURAL INVARIANT, not a comment about it: whatever directory the
  # real spawn stages the credential into is the directory the remover
  # resolves. This fails the moment those two answers diverge, which is exactly
  # the shape of the defect it replaces - the stager followed the task home
  # while every remover re-derived the controller's.
  local record id parent out status staged resolved
  id=child-c4
  parent=smc-resolve
  record=$(make_child_case child-resolve "$id" "$parent")
  read_child_case "$record"
  stand_up_compartment "$CASE_DIR" "$PRIMARY_DIR" "$parent" gen-parent \
    || fail "the parent compartment could not be stood up in the primary's controller"
  assert_fixture_provider_drove_the_lane "$CASE_DIR"
  out=$(FM_SPAWN_PARENT_TASK="$parent" FM_SPAWN_PARENT_TASK_GENERATION=gen-parent \
    run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$SUB_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a compartment child spawn should succeed: $out"
  # Found, not assumed: ask the filesystem which home actually holds it.
  staged=
  for candidate in "$SUB_DIR/state" "$PRIMARY_DIR/state"; do
    [ -f "$candidate/$id.cloud-account/auth.json" ] || continue
    staged=$candidate
    break
  done
  [ -n "$staged" ] || fail "the compartment child spawn staged no provider credential anywhere"
  # The remover's answer, taken the way a lifecycle command running in the
  # CONTROLLER's home actually takes it: from the authorized task home the
  # controller durably recorded for this exact task generation.
  resolved=$(controller_task_state_dir "$PRIMARY_DIR/state/azure-workers/controller.json" \
    "$id" "$PRIMARY_DIR/state")
  [ "$resolved" = "$staged" ] || fail \
    "the credential is staged in $staged but the controller resolves $resolved"
  pass "the staged cloud-account path and its remover resolve the same home"
}

test_compartment_child_refused_request_leaves_no_credential() {
  # The rollback lane: the payload and account staging happen BEFORE the
  # controller sees the request, so a refusal after staging must take them with
  # it, in the COMPARTMENT's home rather than the primary's. The refusal here
  # is a real controller refusal, the named parent compartment holding no
  # assignment. Scope, precisely: since #280 the credential itself is written
  # after the request succeeds, by the narrowing step, so what this lane proves
  # is the transport removal. The credential-bearing failure that comes after a
  # SUCCESSFUL request is #280's own bind-failure path, and it exits through
  # the same wrapper withdraw the lane above drives end to end.
  local record id parent out status
  id=child-c5
  parent=smc-rollback
  record=$(make_child_case child-rollback "$id" "$parent")
  read_child_case "$record"
  out=$(FM_SPAWN_PARENT_TASK="$parent" FM_SPAWN_PARENT_TASK_GENERATION=gen-parent \
    run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$SUB_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 1 "$status" "a compartment child whose request is refused should fail: $out"
  assert_contains "$out" "cloud worker request was refused" \
    "the refusal did not surface the request failure: $out"
  assert_absent "$SUB_DIR/state/$id.cloud-account/auth.json" \
    "a refused compartment child left its staged provider credential behind"
  assert_absent "$SUB_DIR/state/$id.cloud-account" \
    "a refused compartment child left its account staging directory behind"
  assert_absent "$SUB_DIR/state/$id.cloud-payload" \
    "a refused compartment child left its payload staging directory behind"
  assert_absent "$SUB_DIR/state/$id.cloud-entrypoint" \
    "a refused compartment child left its persisted entrypoint behind"
  assert_absent "$SUB_DIR/state/$id.cloud-worktree" \
    "a refused compartment child left its leased worktree pointer behind"
  assert_absent "$SUB_DIR/state/$id.meta" "a refused compartment child left task metadata behind"
  pass "a compartment child request refused after staging takes its credential with it"
}

test_compartment_child_withdraw_removes_the_staged_credential() {
  # THE DEFECT. bin/fm-spawn.sh stages a PLAINTEXT provider credential at
  # <task home>/state/<id>.cloud-account/auth.json, and since the task-home
  # split the compartment child's task home is the SECONDMATE's home. withdraw
  # owns that removal for a request that never reached assignment, and it
  # resolved the PRIMARY's state, so the credential outlived the task in the
  # compartment home with nothing left that would ever remove it.
  local record id parent out status generation credential
  id=child-c3
  parent=smc-withdraw
  record=$(make_child_case child-withdraw "$id" "$parent")
  read_child_case "$record"
  stand_up_compartment "$CASE_DIR" "$PRIMARY_DIR" "$parent" gen-parent \
    || fail "the parent compartment could not be stood up in the primary's controller"
  assert_fixture_provider_drove_the_lane "$CASE_DIR"
  # Past-policy spend steers the child's admission to a refusal, so it is
  # admitted to the queue and never assigned: withdraw's exact input.
  raise_fixture_actual_cost "$CASE_DIR" 2000
  out=$(FM_SPAWN_PARENT_TASK="$parent" \
    FM_SPAWN_PARENT_TASK_GENERATION=gen-parent \
    run_child_spawn "$CASE_DIR" "$PRIMARY_DIR" "$SUB_DIR" "$WORKTREE_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR")
  status=$?
  expect_code 0 "$status" "a queued compartment child spawn should succeed: $out"
  credential="$SUB_DIR/state/$id.cloud-account/auth.json"
  assert_present "$credential" "the child spawn staged no credential in the compartment home"
  assert_absent "$PRIMARY_DIR/state/$id.cloud-account/auth.json" \
    "the child's credential was staged in the primary home instead of the task home"
  generation=$(child_queue_generation "$PRIMARY_DIR/state/azure-workers/controller.json" "$id")
  [ -n "$generation" ] || fail "the queued child has no controller generation to withdraw"
  out=$(run_child_lifecycle "$CASE_DIR" "$FAKEBIN_DIR" "$PRIMARY_DIR" withdraw \
    --task "$id" --task-generation "$generation" \
    --confirm-withdraw --confirm-subscription "$SUB")
  status=$?
  expect_code 0 "$status" "withdrawing the queued compartment child should succeed: $out"
  assert_contains "$out" "FM-WITHDREW $id" "withdraw emitted no receipt for the child: $out"
  assert_absent "$credential" \
    "withdraw left the child's staged provider credential in the compartment home"
  assert_absent "$SUB_DIR/state/$id.cloud-account" \
    "withdraw left the child's account staging directory in the compartment home"
  pass "withdrawing a compartment child removes the credential from the home it staged it in"
}

test_cloud_switch_off_keeps_the_local_path_and_metadata_shape
test_cloud_spawn_places_worker_and_runs_the_entrypoint
test_cloud_spawn_uses_the_dedicated_azure_account_pool
test_cloud_spawn_refuses_an_unsafe_azure_account_pool_path
test_cloud_spawn_refuses_a_gap_in_the_azure_account_pool
test_cloud_spawn_refuses_a_credential_that_could_refresh_on_the_guest
test_monitor_lands_the_outcome_bundle
test_monitor_reports_an_already_landed_outcome
test_monitor_reports_a_crewmate_that_never_committed
test_monitor_lands_despite_a_collection_error
test_monitor_keeps_the_outcome_when_the_worktree_moved
test_cloud_spawn_stays_durably_queued_without_admission
test_cloud_monitor_launch_carries_fm_home
test_persisted_cloud_env_matches_the_deployment_read_set_exactly
test_respawn_sweeps_stale_cloud_artifacts
test_queued_spawn_converges_through_the_monitor
test_monitor_stands_down_when_dispatch_already_claimed
test_cloud_spawn_config_file_default_and_env_override
test_azure_only_routes_every_new_ship_and_scout_without_local_fallback
test_azure_only_precedence_cannot_be_loosened_and_environment_can_tighten
test_azure_only_refuses_incompatible_and_recovery_routes_before_mutation
test_azure_only_preserves_existing_local_and_unlanded_work
test_cloud_spawn_refuses_unknown_switch_value
test_cloud_spawn_requires_safe_durable_controller_config_before_mutation
test_a_spawn_that_cannot_stage_its_snapshot_removes_projection
test_the_pool_is_never_staged_in_the_request_to_narrow_window
test_cloud_switch_refuses_non_pi_harness
test_cloud_switch_refuses_explicit_backend
test_compartment_child_spawn_splits_the_task_home_from_the_money_document
test_task_home_refusals_are_exact
test_compartment_child_withdraw_removes_the_staged_credential
test_compartment_child_refused_request_leaves_no_credential
test_compartment_child_staging_and_removal_resolve_the_same_home

test_cloud_switch_off_and_on_share_the_same_base_metadata

echo "# fm-spawn-cloud.test.sh: all assertions passed"
