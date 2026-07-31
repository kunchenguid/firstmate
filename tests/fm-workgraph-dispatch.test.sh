#!/usr/bin/env bash
# Focused Slice-6 brief/spawn dispatch enforcement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-workgraph-dispatch)
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
DISPATCH_TEST_PARENT_BASHPID=$BASHPID
cleanup_dispatch_test() {
  [ "$BASHPID" = "$DISPATCH_TEST_PARENT_BASHPID" ] || return 0
  if [ -f "$TMP_ROOT/holder-pids" ]; then
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill "$pid" >/dev/null 2>&1 || true
    done <"$TMP_ROOT/holder-pids"
  fi
  fm_test_cleanup
}
trap cleanup_dispatch_test EXIT

make_repo() {
  local root=$1
  mkdir -p "$root/project"
  git -C "$root/project" init -q
  git -C "$root/project" config user.name test
  git -C "$root/project" config user.email test@example.invalid
  printf 'base\n' >"$root/project/base.txt"
  git -C "$root/project" add base.txt
  git -C "$root/project" commit -qm base
  git -C "$root/project" worktree add -q --detach "$root/wt-a"
  git -C "$root/project" worktree add -q --detach "$root/wt-b"
  git -C "$root/project" worktree add -q --detach "$root/wt-c"
  git -C "$root/project" worktree add -q --detach "$root/wt-d"
}

write_fixture() {
  local root=$1 mode_a=${2:-read} mode_b=${3:-read}
  mkdir -p "$root/contracts"
  node - "$root" "$mode_a" "$mode_b" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const modes = {a: process.argv[3], b: process.argv[4], c: "read", d: "write"};
const refs = [];
for (const id of ["a", "b", "c", "d"]) {
  const contract = {
    schema_version: "slice-contract/v1",
    slice_id: id,
    goal_id: "dispatch-goal",
    purpose: `Dispatch ${id}`,
    type: "ship",
    depends_on: [],
    immutable_inputs: [],
    outputs: [`out/${id}.txt`],
    claims: [{resource: "lock://shared-dispatch", mode: modes[id]}],
    worktree: path.join(root, `wt-${id}`),
    harness: "codex",
    model: "gpt-test",
    effort: "high",
    acceptance: ["accepted"],
    validation_commands: ["true"],
    expected_evidence: ["result"],
    context_budget: {source_tokens: 100, report_words: 100},
    gates: ["tests-green"],
    implementer: "worker",
    independent_validators: ["reviewer"],
    authorized_exceptions: [],
  };
  const bytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
  fs.writeFileSync(path.join(root, "contracts", `${id}.json`), bytes);
  refs.push({
    slice_id: id,
    contract_path: `contracts/${id}.json`,
    contract_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  });
}
fs.writeFileSync(path.join(root, "graph.json"), JSON.stringify({
  schema_version: "workgraph/v1",
  goal_id: "dispatch-goal",
  slices: refs,
}, null, 2) + "\n");
fs.writeFileSync(path.join(root, "registry.json"), JSON.stringify({
  schema_version: "resource-registry/v1",
  instances: [{
    id: "shared-dispatch",
    namespace: "lock",
    resource: "lock://shared-dispatch",
    aliases: [],
    contains: [],
  }],
}, null, 2) + "\n");
NODE
}

write_cross_goal_fixture() {
  local root=$1
  mkdir -p "$root/other-contracts"
  node - "$root" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const refs = [];
for (const [id, worktree, outputs, mode] of [
  ["x", "wt-d", ["out/x.txt"], "write"],
  ["y", "wt-c", [path.join(root, "wt-a", "out", "a.txt")], "read"],
]) {
  const contract = {
    schema_version: "slice-contract/v1",
    slice_id: id,
    goal_id: "other-dispatch-goal",
    purpose: `Cross-goal conflicting dispatch ${id}`,
    type: "ship",
    depends_on: [],
    immutable_inputs: [],
    outputs,
    claims: [{resource: "lock://shared-dispatch", mode}],
    worktree: path.join(root, worktree),
    harness: "codex",
    model: "gpt-test",
    effort: "high",
    acceptance: ["accepted"],
    validation_commands: ["true"],
    expected_evidence: ["result"],
    context_budget: {source_tokens: 100, report_words: 100},
    gates: ["tests-green"],
    implementer: `worker-${id}`,
    independent_validators: [`reviewer-${id}`],
    authorized_exceptions: [],
  };
  const bytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
  fs.writeFileSync(path.join(root, "other-contracts", `${id}.json`), bytes);
  refs.push({
    slice_id: id,
    contract_path: `other-contracts/${id}.json`,
    contract_sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
  });
}
fs.writeFileSync(path.join(root, "other-graph.json"), JSON.stringify({
  schema_version: "workgraph/v1",
  goal_id: "other-dispatch-goal",
  slices: refs,
}, null, 2) + "\n");
fs.copyFileSync(path.join(root, "registry.json"), path.join(root, "other-registry.json"));
NODE
}

make_brief() {
  local home=$1 fixture=$2 id=$3
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" "$id" firstmate \
      --workgraph "$fixture/graph.json" --slice "$id" >/dev/null
}

make_brief_graph() {
  local home=$1 graph=$2 id=$3
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-brief.sh" "$id" firstmate \
      --workgraph "$graph" --slice "$id" >/dev/null
}

run_enforce() {
  local home=$1 fixture=$2 id=$3
  local graph=${4:-$fixture/graph.json}
  local registry=${5:-$fixture/registry.json}
  local endpoint_pid
  sleep 2147483647 &
  endpoint_pid=$!
  printf '%s\n' "$endpoint_pid" >>"$TMP_ROOT/holder-pids"
  set +e
  OUTPUT=$(
    {
    FM_ROOT="$ROOT"
    FM_HOME="$home"
    DATA="$home/data"
    STATE="$home/state"
    CONFIG="$home/config"
    export FM_ROOT FM_HOME DATA STATE CONFIG
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-workgraph-dispatch-lib.sh"
    fm_workgraph_load_contract "$id" ship \
      "$graph" "$id" "$registry" || exit
    fm_workgraph_holder_start || exit
    fm_workgraph_enforce_dispatch "$id" "$fixture/project" \
      || { rc=$?; fm_workgraph_abort_release; exit "$rc"; }
    fm_workgraph_handoff_to_endpoint "$endpoint_pid" \
      || { rc=$?; fm_workgraph_abort_release; exit "$rc"; }
    printf '%s\n' "$FM_WORKGRAPH_HOLDER_PID" >>"$TMP_ROOT/holder-pids"
    printf 'goal=%s\nslice=%s\nwave=%s\nworktree=%s\nlease=%s\ntoken=%s\nholder_pid=%s\nholder_start=%s\n' \
      "$FM_WORKGRAPH_GOAL" "$FM_WORKGRAPH_SLICE" "$FM_WORKGRAPH_WAVE" \
      "$FM_WORKGRAPH_WORKTREE" "$FM_WORKGRAPH_LEASE_ID" "$FM_WORKGRAPH_FENCING_TOKEN" \
      "$FM_WORKGRAPH_HOLDER_PID" "$FM_WORKGRAPH_HOLDER_START_TICKS"
    fm_workgraph_dispatch_unlock
    } 2>&1
  )
  RC=$?
  set -e
}

assert_dispatched_holder_survives() {
  local holder_pid holder_start actual_start
  holder_pid=$(printf '%s\n' "$OUTPUT" | sed -n 's/^holder_pid=//p' | tail -n 1)
  holder_start=$(printf '%s\n' "$OUTPUT" | sed -n 's/^holder_start=//p' | tail -n 1)
  case "$holder_pid:$holder_start" in
    *[!0-9:]*|:*|*:) fail "dispatch omitted a numeric holder identity" ;;
  esac
  sleep 0.25
  [ -r "/proc/$holder_pid/stat" ] \
    || fail "lease holder exited after its creator shell returned"
  actual_start=$(awk '{print $22}' "/proc/$holder_pid/stat")
  [ "$actual_start" = "$holder_start" ] \
    || fail "lease holder PID was reused after dispatch"
}

write_meta_from_lease() {
  local home=$1 fixture=$2 id=$3 worktree=$4
  local goal=${5:-dispatch-goal}
  local graph=${6:-$fixture/graph.json}
  local registry=${7:-$fixture/registry.json}
  local values token holder_pid holder_start
  values=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" inspect "$goal" --lease-id "$id" \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const v=JSON.parse(s);process.stdout.write([v.holder_fencing_token,v.holder_process.pid,v.holder_process.start_ticks].join(" "))})')
  read -r token holder_pid holder_start <<EOF
$values
EOF
  {
    printf 'window=fm-%s\n' "$id"
    printf 'endpoint_task_id=%s\n' "$id"
    printf 'worktree=%s\n' "$worktree"
    printf 'project=%s\n' "$fixture/project"
    printf 'harness=codex\nkind=ship\nmode=no-mistakes\nyolo=off\n'
    printf 'workgraph_goal=%s\n' "$goal"
    printf 'workgraph_slice=%s\n' "$id"
    printf 'workgraph_graph=%s\n' "$graph"
    printf 'workgraph_graph_sha256=%s\n' "$(sha256sum "$graph" | awk '{print $1}')"
    printf 'workgraph_contract_sha256=%s\n' \
      "$("$ROOT/bin/fm-workgraph.sh" contract "$graph" "$id" | sha256sum | awk '{print $1}')"
    printf 'workgraph_registry=%s\n' "$registry"
    printf 'workgraph_registry_sha256=%s\n' "$(sha256sum "$registry" | awk '{print $1}')"
    printf 'workgraph_lease_id=%s\n' "$id"
    printf 'workgraph_fencing_token=%s\n' "$token"
    printf 'workgraph_holder_pid=%s\n' "$holder_pid"
    printf 'workgraph_holder_start_ticks=%s\n' "$holder_start"
  } >"$home/state/$id.meta"
}

test_compatible_dispatch_and_capacity() {
  local fixture="$TMP_ROOT/fixture" home="$TMP_ROOT/home" history
  make_repo "$fixture"
  write_fixture "$fixture"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'eco\n' >"$home/config/parallelism"
  make_brief "$home" "$fixture" a
  make_brief "$home" "$fixture" b
  make_brief "$home" "$fixture" c
  run_enforce "$home" "$fixture" a
  expect_code 0 "$RC" "first WorkGraph dispatch"
  assert_contains "$OUTPUT" 'slice=a' "first dispatch omitted slice metadata"
  assert_contains "$OUTPUT" 'wave=0' "first dispatch omitted its static wave"
  assert_dispatched_holder_survives
  history=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" inspect dispatch-goal --history)
  node - "$history" <<'NODE' || fail "dispatch did not publish a terminal provisional lease and a superior endpoint lease"
const records = process.argv[2].trim().split("\n").filter(Boolean).map(JSON.parse);
const provisional = records.find((record) => record.lease_id.startsWith("dispatch-")
  && record.state === "released");
const endpoint = records.find((record) => record.lease_id === "a");
if (records.length !== 3 || !provisional || !endpoint
    || provisional.state !== "released" || endpoint.state !== "held"
    || BigInt(endpoint.holder_fencing_token) <= BigInt(provisional.current_fencing_token)) {
  process.exit(1);
}
NODE
  write_meta_from_lease "$home" "$fixture" a "$fixture/wt-a"
  run_enforce "$home" "$fixture" b
  expect_code 0 "$RC" "compatible read/read WorkGraph dispatch"
  write_meta_from_lease "$home" "$fixture" b "$fixture/wt-b"
  run_enforce "$home" "$fixture" c
  [ "$RC" -ne 0 ] || fail "eco mode admitted a third active WorkGraph task"
  assert_contains "$OUTPUT" 'parallelism mode eco has reached capacity 2' \
    "eco capacity refusal diagnostic changed"
  pass "WorkGraph dispatch admits compatible read/read slices and enforces eco capacity"
}

test_resource_and_legacy_refusals() {
  local fixture="$TMP_ROOT/conflict-fixture" home="$TMP_ROOT/conflict-home" token
  make_repo "$fixture"
  write_fixture "$fixture" read read
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'on\n' >"$home/config/parallelism"
  make_brief "$home" "$fixture" a
  make_brief "$home" "$fixture" d
  run_enforce "$home" "$fixture" a
  expect_code 0 "$RC" "conflict fixture first dispatch"
  write_meta_from_lease "$home" "$fixture" a "$fixture/wt-a"
  run_enforce "$home" "$fixture" d
  [ "$RC" -ne 0 ] || fail "write claim overlapped an active read lease"
  assert_contains "$OUTPUT" 'sealed contract conflicts with active task a' \
    "resource conflict diagnostic changed"

  rm -f "$home/state/a.meta"
  token=$(FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" inspect dispatch-goal --lease-id a \
    | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).holder_fencing_token))')
  FM_HOME="$home" "$ROOT/bin/fm-workgraph.sh" release dispatch-goal \
    --lease-id a --holder-id a --fencing-token "$token" >/dev/null
  printf 'window=fm-legacy\nworktree=%s\nkind=ship\n' "$fixture/wt-a" >"$home/state/legacy.meta"
  run_enforce "$home" "$fixture" d
  [ "$RC" -ne 0 ] || fail "WorkGraph dispatch ran beside legacy metadata"
  assert_contains "$OUTPUT" 'is legacy, ambiguous, or lacks a valid held lease' \
    "legacy-active refusal diagnostic changed"
  pass "WorkGraph dispatch rejects write/read conflicts and active legacy tasks"
}

test_cross_goal_conflict_refuses_before_lease() {
  local fixture="$TMP_ROOT/cross-goal-fixture"
  local home="$TMP_ROOT/cross-goal-home"
  make_repo "$fixture"
  write_fixture "$fixture" read read
  write_cross_goal_fixture "$fixture"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'on\n' >"$home/config/parallelism"
  make_brief "$home" "$fixture" a
  make_brief_graph "$home" "$fixture/other-graph.json" x
  make_brief_graph "$home" "$fixture/other-graph.json" y

  run_enforce "$home" "$fixture" a
  expect_code 0 "$RC" "cross-goal fixture first dispatch"
  write_meta_from_lease "$home" "$fixture" a "$fixture/wt-a"

  run_enforce "$home" "$fixture" x \
    "$fixture/other-graph.json" "$fixture/other-registry.json"
  [ "$RC" -ne 0 ] || fail "cross-goal write/read collision was admitted"
  assert_contains "$OUTPUT" 'sealed contract conflicts with active task a' \
    "cross-goal conflict refusal diagnostic changed"
  [ ! -e "$home/data/workgraphs/.leases/v1/records/other-dispatch-goal/x/1.json" ] \
    || fail "cross-goal conflict created a lease before refusal"

  run_enforce "$home" "$fixture" y \
    "$fixture/other-graph.json" "$fixture/other-registry.json"
  [ "$RC" -ne 0 ] || fail "cross-goal output collision was admitted"
  assert_contains "$OUTPUT" 'sealed contract conflicts with active task a' \
    "cross-goal output refusal diagnostic changed"
  [ ! -e "$home/data/workgraphs/.leases/v1/records/other-dispatch-goal/y/1.json" ] \
    || fail "cross-goal output conflict created a lease before refusal"
  pass "WorkGraph dispatch rejects claim and output conflicts across distinct goal IDs"
}

test_spawn_legacy_path_rejects_before_backend_creation() {
  local fixture="$TMP_ROOT/spawn-fixture" home="$TMP_ROOT/spawn-home" out rc
  make_repo "$fixture"
  mkdir -p "$home/data/new-task" "$home/state" "$home/config"
  printf 'legacy brief\n' >"$home/data/new-task/brief.md"
  printf 'window=fm-existing\nworktree=%s\nkind=ship\n' "$fixture/wt-a" >"$home/state/existing.meta"
  set +e
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" new-task "$fixture/project" --harness codex 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "fm-spawn admitted a legacy task beside active metadata"
  assert_contains "$out" 'legacy task new-task is exclusive while active task metadata exists' \
    "fm-spawn did not expose the WorkGraph legacy refusal"
  [ ! -e "$home/state/new-task.meta" ] \
    || fail "refused legacy spawn published task metadata"
  pass "fm-spawn rejects known legacy collisions before backend creation"
}

test_contract_binding_mismatch_fails_before_lease() {
  local fixture="$TMP_ROOT/binding-fixture" home="$TMP_ROOT/binding-home"
  make_repo "$fixture"
  write_fixture "$fixture"
  mkdir -p "$home/data" "$home/state" "$home/config"
  make_brief "$home" "$fixture" a
  printf '\n' >>"$home/data/a/slice-contract.json"
  run_enforce "$home" "$fixture" a
  [ "$RC" -ne 0 ] || fail "tampered brief contract snapshot reached dispatch"
  assert_contains "$OUTPUT" 'brief contract snapshot differs from the sealed graph bytes' \
    "tampered contract binding diagnostic changed"
  [ ! -e "$home/data/workgraphs/.leases/v1/records/dispatch-goal/a/1.json" ] \
    || fail "tampered contract snapshot created a lease"
  pass "dispatch binds the brief snapshot to the exact graph bytes before mutation"
}

test_contract_accepts_explicit_no_effort_axis() {
  local fixture="$TMP_ROOT/default-effort-fixture" home="$TMP_ROOT/default-effort-home"
  make_repo "$fixture"
  write_fixture "$fixture"
  node - "$fixture" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const root = process.argv[2];
const contractPath = path.join(root, "contracts", "a.json");
const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
contract.harness = "minimax";
contract.model = "MiniMax-M3";
contract.effort = "default";
const bytes = Buffer.from(JSON.stringify(contract, null, 2) + "\n");
fs.writeFileSync(contractPath, bytes);
const graphPath = path.join(root, "graph.json");
const graph = JSON.parse(fs.readFileSync(graphPath, "utf8"));
graph.slices.find((entry) => entry.slice_id === "a").contract_sha256 =
  crypto.createHash("sha256").update(bytes).digest("hex");
fs.writeFileSync(graphPath, JSON.stringify(graph, null, 2) + "\n");
NODE
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf 'on\n' >"$home/config/parallelism"
  make_brief "$home" "$fixture" a
  run_enforce "$home" "$fixture" a
  expect_code 0 "$RC" "WorkGraph contract with no separate effort axis"
  assert_contains "$OUTPUT" 'slice=a' \
    "default-effort contract did not pass sealed dispatch admission"
  pass "WorkGraph dispatch records effort=default for harnesses with no separate axis"
}

test_workgraph_brief_replaces_legacy_delivery_instructions() {
  local fixture="$TMP_ROOT/brief-contract-fixture" home="$TMP_ROOT/brief-contract-home" brief
  make_repo "$fixture"
  write_fixture "$fixture"
  mkdir -p "$home/data" "$home/state" "$home/config"
  make_brief "$home" "$fixture" a
  brief="$home/data/a/brief.md"
  assert_contains "$(cat "$brief")" 'Firstmate is the only canonical integrator' \
    "WorkGraph brief omitted the canonical integration owner"
  assert_contains "$(cat "$brief")" 'Undeclared access is forbidden' \
    "WorkGraph brief omitted its fail-closed capability boundary"
  assert_not_contains "$(cat "$brief")" 'git checkout -b' \
    "WorkGraph brief retained the legacy branch creation instruction"
  assert_not_contains "$(cat "$brief")" 'no-mistakes' \
    "WorkGraph brief retained the legacy delivery pipeline"
  assert_not_contains "$(cat "$brief")" 'gh-axi' \
    "WorkGraph brief retained the legacy PR workflow"
  pass "WorkGraph briefs are governed only by sealed claims, gates, outputs, and Firstmate integration"
}

test_compatible_dispatch_and_capacity
test_resource_and_legacy_refusals
test_cross_goal_conflict_refuses_before_lease
test_spawn_legacy_path_rejects_before_backend_creation
test_contract_binding_mismatch_fails_before_lease
test_contract_accepts_explicit_no_effort_axis
test_workgraph_brief_replaces_legacy_delivery_instructions
