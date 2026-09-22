#!/usr/bin/env bash
# Behavior tests for the inert synthetic competition-scientist pilot.
#
# The suite drives only the public command and its documented workspace records.
# It uses deterministic fixture proposals and spends no model tokens.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB="$ROOT/bin/fm-competition-scientist-lab.sh"
TMP_ROOT=$(fm_test_tmproot fm-competition-scientist)

competition_scientist_cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  fm_test_cleanup
}
trap competition_scientist_cleanup EXIT
trap 'competition_scientist_cleanup; exit 130' INT
trap 'competition_scientist_cleanup; exit 143' TERM
trap 'competition_scientist_cleanup; exit 129' HUP
trap 'competition_scientist_cleanup; exit 131' QUIT

write_proposal() { # <path> <id> <hypothesis> <branch> <changes-json> [token-cost] [planning-tokens]
  python3 - "$@" <<'PY'
import json
import sys
path, proposal_id, hypothesis, branch, changes = sys.argv[1:6]
token_cost = int(sys.argv[6]) if len(sys.argv) > 6 else 0
planning_tokens = int(sys.argv[7]) if len(sys.argv) > 7 else 0
with open(path, "w", encoding="utf-8") as handle:
    json.dump(
        {
            "id": proposal_id,
            "hypothesis": hypothesis,
            "falsifier": "fixture falsifier",
            "changes": json.loads(changes),
            "branch": branch,
            "token_cost": token_cost,
            "planning_tokens": planning_tokens,
        },
        handle,
    )
PY
}

init_workspace() { # <workspace> <task> <controller> [attempts] [wall] [planning]
  local workspace=$1 task=$2 controller=$3 attempts=${4:-8} wall=${5:-2} planning=${6:-9600}
  "$LAB" init --workspace "$workspace" --task "$task" --controller "$controller" \
    --attempts "$attempts" --wall-seconds "$wall" --cpu-seconds 2 \
    --memory-mb 512 --token-budget 48000 --planning-token-budget "$planning" \
    >/dev/null
}

test_help_and_inertness() {
  local output status before after
  before=$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')
  output=$($LAB --help 2>&1); status=$?
  after=$(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')
  expect_code 0 "$status" "lab help should succeed"
  assert_contains "$output" "never invokes an LLM or submits" "help should state inert boundary"
  [ "$before" = "$after" ] || fail "help created runtime state"
  pass "competition scientist: help is inert and documents the external-action boundary"
}

test_smoke_contract() {
  local output root
  root="$TMP_ROOT/smoke"
  output=$($LAB smoke --output "$root" --wall-seconds 2 --cpu-seconds 2 --memory-mb 512)
  assert_contains "$output" "smoke-summary:" "smoke should emit a deterministic summary"
  python3 - "$root" <<'PY'
import hashlib
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
workspaces = sorted(path for path in root.iterdir() if path.is_dir())
assert len(workspaces) == 6, len(workspaces)
for workspace in workspaces:
    final = json.loads((workspace / ".run/final.json").read_text())
    state = json.loads((workspace / ".run/state.json").read_text())
    rows = [json.loads(line) for line in (workspace / ".run/ledger.jsonl").read_text().splitlines()]
    assert final["attempts_used"] == 6
    assert final["sealed_calls"] == 1
    assert state["sealed_calls"] == 1
    assert rows[0]["kind"] == "baseline" and rows[0]["verdict"] == "KEEP"
    assert all(row["evaluation_repeats"] == 2 for row in rows if row["kind"] in {"baseline", "experiment"} and row["metrics"])
    assert all("sealed" not in row for row in rows if row["kind"] in {"baseline", "experiment"})
    previous = ""
    for row in rows:
        assert row["previous_record_sha256"] == previous
        unsigned = dict(row)
        recorded = unsigned.pop("record_sha256")
        actual = hashlib.sha256(json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        assert actual == recorded
        previous = recorded
    expected_falsification = 1 if final["controller"] == "proposed" else 0
    assert final["falsification_calls"] == expected_falsification
    if final["controller"] == "proposed":
        falsification_rows = [row for row in rows if row["kind"] == "falsification"]
        assert len(falsification_rows) == 1 and falsification_rows[0]["falsifier"]
    candidate = (workspace / "candidate.py").read_bytes()
    assert hashlib.sha256(candidate).hexdigest() == final["selected_candidate_sha256"]
PY
  pass "competition scientist: smoke covers three tasks, both controllers, baseline-first, sealed isolation, and chained ledgers"
}

test_frozen_hash_and_undeclared_edit_guards() {
  local hash_ws engine_ws extra_ws proposal output status
  proposal="$TMP_ROOT/guard-proposal.json"
  write_proposal "$proposal" guard "change the grouped threshold" main '{"GROUPED_THRESHOLD":0.1}'

  hash_ws="$TMP_ROOT/hash-workspace"
  init_workspace "$hash_ws" grouped-classification linear
  [ ! -e "$hash_ws/.frozen/sealed.json" ] || fail "sealed rows were exposed before finalization"
  chmod u+w "$hash_ws/.frozen/dev.json"
  printf '\n' >> "$hash_ws/.frozen/dev.json"
  output=$($LAB attempt "$hash_ws" --proposal "$proposal" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "tampered frozen data should be rejected"
  assert_contains "$output" "immutable-violation:dev.json" "tampered data refusal should name the file"

  engine_ws="$TMP_ROOT/engine-workspace"
  init_workspace "$engine_ws" grouped-classification linear
  chmod u+w "$engine_ws/.frozen/manifest.json"
  python3 - "$engine_ws/.frozen/manifest.json" <<'PY'
import hashlib
import json
import sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    manifest = json.load(handle)
manifest["engine_sha256"] = "0" * 64
unsigned = dict(manifest)
unsigned.pop("manifest_sha256", None)
manifest["manifest_sha256"] = hashlib.sha256(json.dumps(unsigned, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
with open(path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  output=$($LAB attempt "$engine_ws" --proposal "$proposal" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "tampered evaluator binding should be rejected"
  assert_contains "$output" "immutable-violation:evaluator-hash" "tampered evaluator refusal should name its binding"

  extra_ws="$TMP_ROOT/extra-workspace"
  init_workspace "$extra_ws" grouped-classification linear
  printf 'unexpected\n' > "$extra_ws/other.py"
  output=$($LAB attempt "$extra_ws" --proposal "$proposal" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "undeclared workspace file should be rejected"
  assert_contains "$output" "undeclared-file-edit:file:other.py" "undeclared edit refusal should name the file"
  pass "competition scientist: frozen hashes and the single editable surface are enforced"
}

test_failure_recovery_and_rejected_artifacts() {
  local workspace proposal output
  workspace="$TMP_ROOT/failures"
  init_workspace "$workspace" noisy-classification linear 6 1

  for failure in syntax timeout oom network; do
    proposal="$TMP_ROOT/$failure.json"
    write_proposal "$proposal" "$failure-case" "exercise $failure recovery" main "{\"INJECT_FAILURE\":\"$failure\"}"
    output=$($LAB attempt "$workspace" --proposal "$proposal")
    assert_contains "$output" "\"failure_class\":\"$([ "$failure" = network ] && printf network-denied || printf %s "$failure")\"" "$failure should be classified"
  done

  proposal="$TMP_ROOT/recovery.json"
  write_proposal "$proposal" recovery "recover with a valid isolated threshold change" main '{"NOISY_THRESHOLD":0.2}'
  $LAB attempt "$workspace" --proposal "$proposal" >/dev/null

  python3 - "$workspace" <<'PY'
import hashlib
import json
import pathlib
import sys
workspace = pathlib.Path(sys.argv[1])
rows = [json.loads(line) for line in (workspace / ".run/ledger.jsonl").read_text().splitlines()]
failures = [row["failure_class"] for row in rows]
for expected in ("syntax", "timeout", "oom", "network-denied"):
    assert expected in failures, (expected, failures)
for row in rows:
    sha = row.get("candidate_sha256")
    if row["kind"] == "experiment" and sha:
        artifact = workspace / "artifacts" / sha / "candidate.py"
        assert artifact.exists(), artifact
        assert hashlib.sha256(artifact.read_bytes()).hexdigest() == sha
state = json.loads((workspace / ".run/state.json").read_text())
current = hashlib.sha256((workspace / "candidate.py").read_bytes()).hexdigest()
assert current == state["global_best_sha256"]
assert rows[-1]["failure_class"] == ""
PY
  pass "competition scientist: syntax, timeout, OOM, and denied-network failures recover without losing rejected artifacts"
}

test_branch_and_planning_limits() {
  local workspace plateau_ws proposal output status
  output=$($LAB init --workspace "$TMP_ROOT/too-many-branches" --task grouped-classification \
    --controller proposed --branch-factor 3 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "branch factor above two should be refused"
  assert_contains "$output" "branch-factor-may-not-exceed-two" "branch cap refusal should be explicit"
  output=$($LAB init --workspace "$TMP_ROOT/too-much-planning" --task grouped-classification \
    --controller proposed --token-budget 100 --planning-token-budget 21 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "planning share above twenty percent should be refused"
  assert_contains "$output" "planning-budget-may-not-exceed-twenty-percent" "planning share refusal should be explicit"

  plateau_ws="$TMP_ROOT/policy-is-not-plateau"
  init_workspace "$plateau_ws" grouped-classification proposed 6 2
  write_proposal "$TMP_ROOT/policy-early.json" policy-early "invalid early branch" branch-a '{"GROUPED_THRESHOLD":0.1}'
  $LAB attempt "$plateau_ws" --proposal "$TMP_ROOT/policy-early.json" >/dev/null
  write_proposal "$TMP_ROOT/policy-confounded.json" policy-confounded "invalid confounded idea" main '{"GROUPED_THRESHOLD":0.1,"GROUPED_CAUSAL_WEIGHT":0.5}'
  $LAB attempt "$plateau_ws" --proposal "$TMP_ROOT/policy-confounded.json" >/dev/null
  write_proposal "$TMP_ROOT/one-real-reject.json" one-real-reject "one empirical rejection" main '{"GROUPED_CAUSAL_WEIGHT":0.45}'
  $LAB attempt "$plateau_ws" --proposal "$TMP_ROOT/one-real-reject.json" >/dev/null
  write_proposal "$TMP_ROOT/premature-after-policy.json" premature-after-policy "policy failures are not a plateau" branch-a '{"GROUPED_SPURIOUS_WEIGHT":0.0}'
  output=$($LAB attempt "$plateau_ws" --proposal "$TMP_ROOT/premature-after-policy.json")
  assert_contains "$output" "branch-before-plateau" "policy rejects should not unlock branching"

  workspace="$TMP_ROOT/branches"
  init_workspace "$workspace" grouped-classification proposed 8 2

  proposal="$TMP_ROOT/early-branch.json"
  write_proposal "$proposal" early-branch "branch before the linear prefix" branch-early '{"GROUPED_THRESHOLD":0.1}'
  output=$($LAB attempt "$workspace" --proposal "$proposal")
  assert_contains "$output" "branch-before-four-attempts" "early branch should be rejected"

  write_proposal "$TMP_ROOT/main-a.json" main-a "first poor linear idea" main '{"GROUPED_CAUSAL_WEIGHT":0.45}'
  write_proposal "$TMP_ROOT/main-b.json" main-b "second poor linear idea" main '{"GROUPED_SPURIOUS_WEIGHT":1.2}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/main-a.json" >/dev/null
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/main-b.json" >/dev/null

  write_proposal "$TMP_ROOT/branch-a.json" branch-a "first distinct branch" branch-a '{"GROUPED_SPURIOUS_WEIGHT":0.0}'
  write_proposal "$TMP_ROOT/branch-b.json" branch-b "second distinct branch" branch-b '{"GROUPED_CAUSAL_WEIGHT":1.2}'
  write_proposal "$TMP_ROOT/branch-c.json" branch-c "third distinct branch" branch-c '{"GROUPED_THRESHOLD":-0.2}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/branch-a.json" >/dev/null
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/branch-b.json" >/dev/null
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/branch-c.json")
  assert_contains "$output" "branch-factor-exceeded" "third branch should be rejected"

  workspace="$TMP_ROOT/planning"
  init_workspace "$workspace" grouped-classification proposed 6 2 10
  write_proposal "$TMP_ROOT/plan-a.json" plan-a "poor plan a" main '{"GROUPED_CAUSAL_WEIGHT":0.45}'
  write_proposal "$TMP_ROOT/plan-b.json" plan-b "poor plan b" main '{"GROUPED_SPURIOUS_WEIGHT":1.2}'
  write_proposal "$TMP_ROOT/plan-c.json" plan-c "poor plan c" main '{"GROUPED_THRESHOLD":0.2}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/plan-a.json" >/dev/null
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/plan-b.json" >/dev/null
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/plan-c.json" >/dev/null
  write_proposal "$TMP_ROOT/over-plan.json" over-plan "spend too much planning budget" branch-a '{"GROUPED_SPURIOUS_WEIGHT":0.0}' 0 11
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/over-plan.json")
  assert_contains "$output" "planning-budget-exceeded" "planning overrun should be rejected"
  pass "competition scientist: linear prefix, plateau, branch factor, and planning caps are enforced"
}

test_duplicate_confounded_and_budget_rejections() {
  local workspace output
  workspace="$TMP_ROOT/proposals"
  init_workspace "$workspace" nonlinear-regression linear 7 2

  write_proposal "$TMP_ROOT/one.json" one "try one bias shift" main '{"REGRESSION_BIAS":0.5}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/one.json" >/dev/null
  write_proposal "$TMP_ROOT/duplicate-hypothesis.json" two "try one bias shift" main '{"REGRESSION_SCALE":0.8}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/duplicate-hypothesis.json")
  assert_contains "$output" "duplicate-hypothesis" "duplicate hypothesis should be rejected"

  write_proposal "$TMP_ROOT/duplicate-candidate.json" three "reach the same candidate another way" main '{"REGRESSION_BIAS":0.5}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/duplicate-candidate.json")
  assert_contains "$output" "duplicate-candidate" "duplicate candidate should be rejected"

  write_proposal "$TMP_ROOT/confounded.json" confounded "change two controls together" main '{"REGRESSION_SCALE":0.8,"REGRESSION_BIAS":0.1}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/confounded.json")
  assert_contains "$output" "confounded-hypothesis" "confounded proposal should be rejected"

  cat > "$TMP_ROOT/self-verdict.json" <<'JSON'
{"id":"self-verdict","hypothesis":"try to decide acceptance","changes":{"REGRESSION_SCALE":0.7},"verdict":"KEEP"}
JSON
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/self-verdict.json")
  assert_contains "$output" "proposal-unknown-fields:verdict" "proposal should not be able to supply a verdict"

  write_proposal "$TMP_ROOT/tokens.json" tokens "exceed the token budget" main '{"REGRESSION_SCALE":0.7}' 48001 0
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/tokens.json")
  assert_contains "$output" "token-budget-exceeded" "token overrun should be rejected"
  pass "competition scientist: duplicate, confounded, self-verdict, and token-overrun proposals are rejected"
}

test_finish_is_idempotent_and_replayable() {
  local workspace first second
  workspace="$TMP_ROOT/finish"
  $LAB run --workspace "$workspace" --task nonlinear-regression --controller proposed \
    --fixture --wall-seconds 2 --cpu-seconds 2 --memory-mb 512 >/dev/null
  first=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')
  $LAB finish "$workspace" >/dev/null
  second=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')
  [ "$first" = "$second" ] || fail "idempotent finish changed the final record"
  $LAB replay "$workspace" >/dev/null
  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
workspace = pathlib.Path(sys.argv[1])
state = json.loads((workspace / ".run/state.json").read_text())
final = json.loads((workspace / ".run/final.json").read_text())
assert state["sealed_calls"] == 1
assert state["falsification_calls"] == 1
assert final["sealed_calls"] == 1
assert final["falsification_calls"] == 1
PY
  pass "competition scientist: final falsification and sealed audit run once and visible candidates replay"
}

test_help_and_inertness
test_smoke_contract
test_frozen_hash_and_undeclared_edit_guards
test_failure_recovery_and_rejected_artifacts
test_branch_and_planning_limits
test_duplicate_confounded_and_budget_rejections
test_finish_is_idempotent_and_replayable

echo "# fm-competition-scientist-lab.test.sh: all assertions passed"
