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
  rm "$extra_ws/other.py"

  printf 'partial' > "$extra_ws/.run/.state.json.4242.tmp"
  printf 'partial' > "$extra_ws/.run/tmp/.evaluation-7-9.json.4242.tmp"
  output=$($LAB attempt "$extra_ws" --proposal "$proposal" 2>&1); status=$?
  expect_code 0 "$status" "an interrupted harness-owned atomic write should not brick the workspace"
  printf 'x' > "$extra_ws/.run/.secrets.tmp"
  output=$($LAB replay "$extra_ws" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a temp-looking file with no declared target should still be rejected"
  assert_contains "$output" "undeclared-file-edit:file:.run/.secrets.tmp" "the tolerated pattern must not admit arbitrary files"
  pass "competition scientist: frozen hashes and the single editable surface are enforced"
}

test_failure_recovery_and_rejected_artifacts() {
  local workspace proposal output
  workspace="$TMP_ROOT/failures"
  init_workspace "$workspace" noisy-classification linear 7 1

  local threshold=0.04
  for failure in syntax timeout oom network; do
    proposal="$TMP_ROOT/$failure.json"
    threshold=$(python3 -c 'import sys; print(round(float(sys.argv[1]) + 0.01, 2))' "$threshold")
    write_proposal "$proposal" "$failure-case" "exercise $failure recovery" main "{\"NOISY_THRESHOLD\":$threshold}"
    output=$($LAB attempt "$workspace" --proposal "$proposal" --inject-failure "$failure")
    assert_contains "$output" "\"failure_class\":\"$([ "$failure" = network ] && printf network-denied || printf %s "$failure")\"" "$failure should be classified"
  done

  write_proposal "$TMP_ROOT/lever-injection.json" lever-injection "smuggle a fault through the proposal surface" main '{"INJECT_FAILURE":"timeout"}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/lever-injection.json")
  assert_contains "$output" "out-of-scope-lever:INJECT_FAILURE" "a proposal must not be able to select a failure injection"

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

test_worst_group_trade_and_per_metric_floors() {
  local workspace output
  workspace="$TMP_ROOT/selection"
  init_workspace "$workspace" grouped-classification linear 5 2

  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
manifest = json.loads((pathlib.Path(sys.argv[1]) / ".frozen/manifest.json").read_text())
floors = manifest["noise_floor"]
assert sorted(floors) == ["calibration_loss", "grouped_mean", "ood_stress", "worst_group"], floors
assert len(set(floors.values())) > 1, floors
assert max(floors.values()) > 0.03, floors
PY

  write_proposal "$TMP_ROOT/drop-spurious.json" drop-spurious "remove the feature whose relationship flips in stress groups" main '{"GROUPED_SPURIOUS_WEIGHT":0.0}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/drop-spurious.json")
  assert_contains "$output" '"decision_reason":"lexicographic:worst_group"' "raising the worst group should reach the lexicographic test"
  assert_contains "$output" '"verdict":"KEEP"' "a candidate that raises every group above the incumbent worst-group floor should be kept"

  write_proposal "$TMP_ROOT/sink-group.json" sink-group "remove the stable causal signal entirely" main '{"GROUPED_CAUSAL_WEIGHT":0.0}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/sink-group.json")
  assert_contains "$output" '"decision_reason":"catastrophic-group-regression' "a candidate that sinks a group below the incumbent floor should still be vetoed"
  assert_contains "$output" '"verdict":"REVERT"' "the vetoed candidate should revert"
  pass "competition scientist: the worst-group objective survives a subgroup trade and each metric carries its own floor"
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
  init_workspace "$workspace" nonlinear-regression linear 8 2

  write_proposal "$TMP_ROOT/one.json" one "try one bias shift" main '{"REGRESSION_BIAS":0.5}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/one.json" >/dev/null
  write_proposal "$TMP_ROOT/duplicate-hypothesis.json" two "try one bias shift" main '{"REGRESSION_SCALE":0.8}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/duplicate-hypothesis.json")
  assert_contains "$output" "duplicate-hypothesis" "duplicate hypothesis should be rejected"

  write_proposal "$TMP_ROOT/duplicate-candidate.json" three "reach the same candidate another way" main '{"REGRESSION_BIAS":0.5}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/duplicate-candidate.json")
  assert_contains "$output" "duplicate-candidate" "duplicate candidate should be rejected"

  write_proposal "$TMP_ROOT/reused-hypothesis.json" four "reach the same candidate another way" main '{"REGRESSION_BIAS":0.25}'
  output=$($LAB attempt "$workspace" --proposal "$TMP_ROOT/reused-hypothesis.json")
  assert_contains "$output" "duplicate-hypothesis" "a hypothesis registered before a duplicate-candidate rejection should stay registered"

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

  workspace="$TMP_ROOT/unparseable"
  printf '%s\n' '{"id":"good","hypothesis":"shift the bias upward","falsifier":"f","changes":{"REGRESSION_BIAS":0.5},"branch":"main","token_cost":0,"planning_tokens":0}' '{not json' \
    > "$TMP_ROOT/unparseable.jsonl"
  output=$($LAB run --workspace "$workspace" --task nonlinear-regression --controller linear \
    --proposals "$TMP_ROOT/unparseable.jsonl" --attempts 4 --wall-seconds 2 --cpu-seconds 2 --memory-mb 512)
  assert_contains "$output" "class=proposal-unparseable" "a malformed proposal line should be classed as unparseable"
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

test_charged_audit_interruption_publishes_a_failed_final_record() {
  local workspace output status first second
  workspace="$TMP_ROOT/interrupted-finish"
  init_workspace "$workspace" noisy-classification linear 3 2

  chmod 0500 "$workspace/.run/tmp"
  $LAB finish "$workspace" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an interrupted sealed audit should not report success"
  chmod 0700 "$workspace/.run/tmp"
  [ -z "$(find "$workspace" -name 'sealed-*.json' -print -quit)" ] \
    || fail "an interrupted finish left the sealed dataset in the proposer-visible workspace"
  first=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')
  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
workspace = pathlib.Path(sys.argv[1])
state = json.loads((workspace / ".run/state.json").read_text())
final = json.loads((workspace / ".run/final.json").read_text())
assert state["complete"] is True, state["complete"]
assert state["sealed_calls"] == 1, state["sealed_calls"]
assert sorted(final["aborted"]) == ["error", "phase"], final["aborted"]
assert final["aborted"]["phase"] == "sealed", final["aborted"]
assert final["aborted"]["error"], final["aborted"]
assert final["sealed"]["failure_class"] == "sealed-not-completed", final["sealed"]
assert final["sealed"]["ok"] is False, final["sealed"]
assert final["falsification"] is None, final["falsification"]
assert final["attempts_used"] == state["attempts_used"]
ledger = [line for line in (workspace / ".run/ledger.jsonl").read_text().splitlines() if line]
assert any(json.loads(line)["kind"] == "baseline" for line in ledger), "prior evidence was discarded"
PY

  output=$($LAB finish "$workspace" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a later finish must not report success for an abandoned search"
  assert_contains "$output" "aborted: task=noisy-classification controller=linear phase=sealed" \
    "a later finish should reprint the recorded outcome"
  second=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')
  [ "$first" = "$second" ] || fail "a later finish re-ran a charged one-shot call"
  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
state = json.loads((pathlib.Path(sys.argv[1]) / ".run/state.json").read_text())
assert state["sealed_calls"] == 1, state["sealed_calls"]
assert state["falsification_calls"] == 0, state["falsification_calls"]
PY
  output=$($LAB replay "$workspace" 2>&1); status=$?
  expect_code 0 "$status" "replay should audit a terminal failed record instead of calling it a mismatch"
  assert_contains "$output" "aborted=sealed" "replay should name the phase that was charged but never completed"
  pass "competition scientist: an interrupted charged audit ends the search with an auditable failed final record"
}

test_interrupted_falsification_record_replays_as_aborted() {
  local workspace output status
  workspace="$TMP_ROOT/falsification-abort"
  init_workspace "$workspace" noisy-classification proposed 3 2

  chmod 0400 "$workspace/.run/results.tsv"
  $LAB finish "$workspace" >/dev/null 2>&1
  status=$?
  [ "$status" -ne 0 ] || fail "an interrupted falsification should not report success"
  chmod 0600 "$workspace/.run/results.tsv"
  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
workspace = pathlib.Path(sys.argv[1])
state = json.loads((workspace / ".run/state.json").read_text())
final = json.loads((workspace / ".run/final.json").read_text())
assert final["aborted"]["phase"] == "falsification", final["aborted"]
assert final["sealed"]["failure_class"] == "", final["sealed"]
assert final["sealed_calls"] == 0, final["sealed_calls"]
assert state["sealed_calls"] == 0, state["sealed_calls"]
assert state["falsification_calls"] == 1, state["falsification_calls"]
PY

  output=$($LAB replay "$workspace" 2>&1); status=$?
  expect_code 0 "$status" "an uncharged sealed audit must not be reported as evidence tampering"
  assert_contains "$output" "sealed_calls=0 aborted=falsification" "replay should report the real charged-call count"

  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1]) / ".run/final.json"
final = json.loads(path.read_text())
final["sealed_calls"] = 1
path.chmod(0o600)
path.write_text(json.dumps(final, indent=2, sort_keys=True) + "\n")
PY
  output=$($LAB replay "$workspace" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a final record disagreeing with the charged count should still be refused"
  assert_contains "$output" "replay-mismatch:sealed-call-count" "count tampering should still be named"

  python3 - "$workspace" <<'@@'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1]) / ".run/final.json"
final = json.loads(path.read_text())
final["sealed_calls"] = 0
final["falsification_calls"] = 7
path.chmod(0o600)
path.write_text(json.dumps(final, indent=2, sort_keys=True) + "\n")
@@
  output=$($LAB replay "$workspace" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "the other charged counter must be audited too"
  assert_contains "$output" "replay-mismatch:falsification-call-count" "falsification count tampering should be named"
  pass "competition scientist: replay audits an aborted final record and still catches a forged call count"
}

test_falsification_failure_names_the_failing_arm() {
  local workspace baseline best output status
  workspace="$TMP_ROOT/falsification-arms"
  init_workspace "$workspace" grouped-classification proposed 4 2
  write_proposal "$TMP_ROOT/drop-flip.json" drop-flip "remove the feature whose relationship flips" main '{"GROUPED_SPURIOUS_WEIGHT":0.0}'
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/drop-flip.json" >/dev/null
  baseline=$(python3 -c 'import json,pathlib,sys; print(json.loads((pathlib.Path(sys.argv[1]) / ".run/state.json").read_text())["baseline_sha256"])' "$workspace")
  best=$(python3 -c 'import json,pathlib,sys; print(json.loads((pathlib.Path(sys.argv[1]) / ".run/state.json").read_text())["global_best_sha256"])' "$workspace")
  [ "$baseline" != "$best" ] || fail "fixture did not promote a candidate above the baseline"

  chmod u+w "$workspace/artifacts/$baseline/candidate.py"
  printf 'BROKEN =\n' > "$workspace/artifacts/$baseline/candidate.py"
  output=$($LAB finish "$workspace" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a failed control arm must still abort the charged phase"
  assert_contains "$output" "falsification-evaluation-failed:baseline-" \
    "the abort should say which falsification arm failed"

  python3 - "$workspace" <<'PY'
import json
import pathlib
import sys
workspace = pathlib.Path(sys.argv[1])
ledger = [json.loads(line) for line in (workspace / ".run/ledger.jsonl").read_text().splitlines() if line]
row = [r for r in ledger if r["kind"] == "falsification"][0]
final = json.loads((workspace / ".run/final.json").read_text())
candidate_wall = row["wall_seconds"]
assert row["failure_class"].startswith("baseline-"), row["failure_class"]
assert row["metrics"] is not None, "the candidate arm scored, so its metrics belong in the record"
assert candidate_wall > 0.0, candidate_wall
assert final["falsification"]["ok"] is True, final["falsification"]
assert final["falsification"]["metrics"] is not None, final["falsification"]
assert final["falsification"]["failure_class"] == "", final["falsification"]
assert final["aborted"]["phase"] == "falsification", final["aborted"]
assert "baseline-" in final["aborted"]["error"], final["aborted"]
PY
  pass "competition scientist: a failed falsification control arm is not charged to the selected candidate"
}

test_results_tsv_keeps_a_fixed_column_count() {
  local workspace
  workspace="$TMP_ROOT/tsv-columns"
  init_workspace "$workspace" noisy-classification linear 5 2

  python3 -c 'import json,sys; json.dump({"id":"x","hypothesis":"h","changes":{"NOISY_THRESHOLD":0.1},"we\tird":1}, open(sys.argv[1],"w"))' "$TMP_ROOT/tab-field.json"
  python3 -c 'import json,sys; json.dump({"id":"y","hypothesis":"h2","changes":{"NOISY_THRESHOLD":0.2},"branch":"a\tb\nc"}, open(sys.argv[1],"w"))' "$TMP_ROOT/tab-branch.json"
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/tab-field.json" >/dev/null 2>&1
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/tab-branch.json" >/dev/null 2>&1

  python3 -c 'import json,sys; json.dump({"id":"u","hypothesis":"a" + chr(0x2028) + "b" + chr(0x85) + "c" + chr(0x0b) + "d","changes":{"NOISY_THRESHOLD":0.3}}, open(sys.argv[1],"w"))' "$TMP_ROOT/unicode-break.json"
  $LAB attempt "$workspace" --proposal "$TMP_ROOT/unicode-break.json" >/dev/null 2>&1

  python3 - "$workspace" <<'PY'
import pathlib
import sys
lines = (pathlib.Path(sys.argv[1]) / ".run/results.tsv").read_text().splitlines()
widths = {len(line.split("\t")) for line in lines}
assert widths == {9}, (widths, lines)
assert len(lines) == 5, lines
PY
  pass "competition scientist: proposal and failure text cannot shift the results.tsv column count"
}

test_failed_audit_evaluation_is_a_terminal_failed_record() {
  local workspace controller sha first second output status
  for controller in linear proposed; do
    workspace="$TMP_ROOT/failed-audit-$controller"
    init_workspace "$workspace" noisy-classification "$controller" 3 2
    sha=$(python3 -c 'import json,pathlib,sys; print(json.loads((pathlib.Path(sys.argv[1]) / ".run/state.json").read_text())["global_best_sha256"])' "$workspace")
    cp "$workspace/artifacts/$sha/candidate.py" "$TMP_ROOT/restore-$controller.py"
    chmod u+w "$workspace/artifacts/$sha/candidate.py"
    printf 'BROKEN =\n' > "$workspace/artifacts/$sha/candidate.py"

    output=$($LAB finish "$workspace" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "an audit that produced no score must not report success"
    case "$output" in
      *sealed_worst_group*) fail "a failed audit must not print a fabricated sealed score" ;;
    esac
    cat "$TMP_ROOT/restore-$controller.py" > "$workspace/artifacts/$sha/candidate.py"
    first=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')

    python3 - "$workspace" "$controller" <<'PY'
import json
import pathlib
import sys
workspace, controller = pathlib.Path(sys.argv[1]), sys.argv[2]
state = json.loads((workspace / ".run/state.json").read_text())
final = json.loads((workspace / ".run/final.json").read_text())
phase = "falsification" if controller == "proposed" else "sealed"
assert state["complete"] is True, state["complete"]
assert final["aborted"]["phase"] == phase, final["aborted"]
assert "evaluation-failed" in final["aborted"]["error"], final["aborted"]
assert final["sealed"]["ok"] is False, final["sealed"]
assert final["sealed"]["metrics"] is None, final["sealed"]
ledger = [json.loads(line) for line in (workspace / ".run/ledger.jsonl").read_text().splitlines() if line]
assert any(row["kind"] == "baseline" for row in ledger), "prior evidence was discarded"
if phase == "falsification":
    charged = [row for row in ledger if row["kind"] == "falsification"]
    assert len(charged) == 1, charged
    assert charged[0]["verdict"] == "FAIL", charged[0]
    assert charged[0]["failure_class"], charged[0]
    assert final["falsification"]["ok"] is False, final["falsification"]
    assert final["falsification"]["failure_class"], final["falsification"]
PY

    output=$($LAB finish "$workspace" 2>&1); status=$?
    [ "$status" -ne 0 ] || fail "a repaired workspace must not silently re-run a charged audit"
    assert_contains "$output" "aborted: task=noisy-classification controller=$controller" \
      "a later finish should reprint the recorded failure"
    second=$(shasum -a 256 "$workspace/.run/final.json" | awk '{print $1}')
    [ "$first" = "$second" ] || fail "a later finish re-ran the charged audit"

    output=$($LAB replay "$workspace" 2>&1); status=$?
    expect_code 0 "$status" "replay should audit a terminal failed record"
    assert_contains "$output" "aborted=" "replay should name the aborted phase"
  done
  pass "competition scientist: an audit that returns a bounded failure ends the search as a terminal failed record"
}

test_sealed_dataset_never_persists_in_the_workspace() {
  local workspace output status
  workspace="$TMP_ROOT/sealed-residue"
  $LAB run --workspace "$workspace" --task noisy-classification --controller proposed \
    --fixture --wall-seconds 2 --cpu-seconds 2 --memory-mb 512 >/dev/null
  [ -z "$(find "$workspace" -name 'sealed-*.json' -print -quit)" ] \
    || fail "the sealed dataset outlived the single evaluation it was generated for"
  [ -z "$(find "$workspace/.run/tmp" -name 'evaluation-*.json' -print -quit)" ] \
    || fail "evaluator output temporaries accumulated in the workspace"

  printf '[]\n' > "$workspace/.run/tmp/sealed-leaked.json"
  output=$($LAB replay "$workspace" 2>&1); status=$?
  [ "$status" -ne 0 ] || fail "a sealed dataset left in the workspace must not pass the surface check"
  assert_contains "$output" "undeclared-file-edit:file:.run/tmp/sealed-leaked.json" \
    "a leaked sealed dataset should be named, not silently tolerated"
  pass "competition scientist: no sealed dataset survives its evaluation or passes the workspace surface"
}

test_help_and_inertness
test_smoke_contract
test_frozen_hash_and_undeclared_edit_guards
test_failure_recovery_and_rejected_artifacts
test_worst_group_trade_and_per_metric_floors
test_branch_and_planning_limits
test_duplicate_confounded_and_budget_rejections
test_finish_is_idempotent_and_replayable
test_charged_audit_interruption_publishes_a_failed_final_record
test_interrupted_falsification_record_replays_as_aborted
test_failed_audit_evaluation_is_a_terminal_failed_record
test_falsification_failure_names_the_failing_arm
test_results_tsv_keeps_a_fixed_column_count
test_sealed_dataset_never_persists_in_the_workspace

echo "# fm-competition-scientist-lab.test.sh: all assertions passed"
