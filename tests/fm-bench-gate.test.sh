#!/usr/bin/env bash
# Behavior tests for the model-routing benchmark gates: the corrected sampling
# and promotion rule, the common neutral judge panel, positive provenance,
# the derived run and cost manifest, the calibrated evaluator, content-addressed
# archives with a real restore drill, and the fail-closed launch guard.
#
# The isolation gate is covered here for non-vacuity - the probe set really does
# detect a leak, and a denial with no positive control is refused - while the
# full-denial proof needs a real confinement and lives in
# tests/fm-bench-isolation-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-bench-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-bench-gate)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

# Every fixture starts from one corrected plan and then breaks exactly one thing,
# so a refusal is always attributable to the correction under test.
write_plan() {  # <bench-dir> [python-mutation]
  local bench=$1 mutation=${2:-}
  mkdir -p "$bench"
  python3 - "$bench/benchmark.json" "$mutation" <<'PY'
import json, sys

path, mutation = sys.argv[1], sys.argv[2]

def candidate(name, family, harness, model, effort="high", **extra):
    row = {"name": name, "family": family, "harness": harness, "model": model, "effort": effort}
    row.update(extra)
    return row

fable = candidate("Fable 5 High", "anthropic", "claude", "fable")
sol = candidate("GPT 5.6 Sol High", "openai", "pi", "openai-codex/gpt-5.6-sol")
opus5 = candidate("Opus 5 High", "anthropic", "claude", "opus")
glm = candidate("GLM 5.3 Flash", "zai", "pi", "zai/glm-5.3-flash")
terra = candidate("Terra 5.6 High", "openai", "pi", "openai-codex/gpt-5.6-terra")
opus48 = candidate("Opus 4.8 High", "anthropic", "claude", "claude-opus-4-8")
grok = candidate("Grok 4.6", "xai", "cursor", "cursor-grok-4.6-high",
                 effort=None, effort_axis=False, metered_provider="cursor")
composer = candidate("Composer 2.5", "cursor", "cursor", "composer-2.5",
                     effort=None, effort_axis=False, metered_provider="cursor")

def track(prefix, entrants, judges, baseline, cost_class, kinds, **extra):
    row = {
        "packets": [{"id": f"{prefix}{i + 1}", "kind": kinds[i]} for i in range(6)],
        "entrants": entrants,
        "judges": judges,
        "judge_call_unit": "per-candidate-output-per-judge",
        "run_cost_class": cost_class,
    }
    if baseline:
        row["baseline"] = baseline
        row["baseline_packets"] = [f"{prefix}1", f"{prefix}3", f"{prefix}5"]
    row.update(extra)
    return row

neutral_ac = [{"name": "GLM 5.3 Max", "family": "zai"}, {"name": "Grok 4.6 Judge", "family": "xai"}]
neutral_b = [{"name": "Luna 5.6", "family": "mistral"}, {"name": "Nova 3", "family": "cohere"}]
historical_first = ["historical"] + ["synthetic"] * 5

plan = {
    "schema": "fm-bench-plan.v1",
    "benchmark_id": "model-routing-benchmark-test",
    "isolation_mode": "enforced",
    "candidate_disposition": "archive-then-discard",
    "direct_ship": False,
    "approved_cost_class_usd": 1100.0,
    "randomisation_seed": "7f3c1a9e",
    "samples_per_entrant": 6,
    "samples_per_baseline": 3,
    "adaptive_extension": False,
    "sample_winner_rule": {
        "definition": "highest composite under the track's common panel",
        "ties": "an exact tie is a declared tie and breaks the sweep",
        "voids": "a void is rerun as the same approved sample",
        "missing": "no valid final commit is void, not a loss",
    },
    "promotion_rule": {
        "type": "paired-sweep",
        "required_wins": 6,
        "of_samples": 6,
        "practical_margin": 1.0,
        "allow_blocker_class_failure": False,
        "baseline_role": "regression_veto",
        "baseline_veto": {"max_negative_mean_quality_delta": 0.0, "max_losses_of_three": 1},
        "tie_breakers": ["deterministic_evidence", "neutral_judge_pairwise", "declared_tie"],
    },
    "failure_policy": {
        "candidate_caused": "score_zero",
        "evaluator_infrastructure": "void_and_rerun",
        "provider_outage": "void_and_rerun",
        "quota_exhaustion": "void_and_rerun",
        "sibling_access": "blocker_class",
    },
    "timing": {
        "clock": "utc-wall-clock-plus-monotonic-local-receipt",
        "intervals": [
            "dispatch_accepted_to_first_valid_final_commit",
            "first_assistant_event_to_first_valid_final_commit",
        ],
        "queue_trust_delay_recorded": True,
        "no_commit_timeout_s": 10800,
        "no_commit_disposition": "void_and_rerun",
    },
    "cost_model": {
        "job_classes": {
            "planning_run": {"low": 3.0, "base": 5.5, "high": 8.0},
            "implementation_run": {"low": 4.0, "base": 8.0, "high": 12.0},
            "security_run": {"low": 4.0, "base": 8.0, "high": 12.0},
            "spec_authoring": {"low": 3.0, "base": 5.0, "high": 8.0},
            "judge_call": {"low": 1.0, "base": 2.0, "high": 3.0},
            "capture_job": {"low": 0.0, "base": 0.0, "high": 0.0},
        }
    },
    "tracks": {
        "A": track("A", [fable, sol], neutral_ac, opus5, "planning_run", historical_first),
        "B": track(
            "B",
            [glm, grok, composer, terra, opus48],
            neutral_b,
            None,
            "implementation_run",
            ["synthetic"] * 6,
            capture_required=True,
            wave="single-complete",
            spec_author={
                "name": "Fable 5",
                "family": "anthropic",
                "family_adjacency_disclosed": ["Opus 4.8 High"],
            },
            spec_audit=[
                {
                    "packet": f"B{i + 1}",
                    "auditor": "independent spec auditor",
                    "auditor_family": "mistral",
                    "pre_freeze": True,
                    "verdict": "accepted",
                }
                for i in range(6)
            ],
        ),
        "C": track("C", [sol, fable], neutral_ac, opus5, "security_run", historical_first),
    },
}

if mutation:
    exec(mutation, {"plan": plan})

json.dump(plan, open(path, "w"), indent=2, sort_keys=True)
PY
}

write_provenance() {  # <bench-dir> <packet> <mode>
  local bench=$1 packet=$2 mode=$3
  mkdir -p "$bench/provenance"
  if [ "$mode" = cleared ]; then
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "participants":[
  {"task_id":"$packet-author","role":"author","model_id":"zai/glm-5.3-flash","family":"zai","session_id":"pi-1"},
  {"task_id":"$packet-review","role":"reviewer","model_id":"zai/glm-5.3","family":"zai","session_id":"pi-2"}]}
EOF
  else
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "participants":[
  {"task_id":"$packet-author","role":"author","model_id":"no record found","family":"unknown","session_id":"unavailable"}]}
EOF
  fi
}

run_gate() {  # <bench-dir> <gate> [args...]
  local bench=$1
  shift
  "$GATE" --bench "$bench" --probe-timeout 30 "$@" 2>&1
}

# --- the corrected sampling, promotion, and panel rules ---------------------

BENCH="$TMP_ROOT/plan-ok"
write_plan "$BENCH"
out=$(run_gate "$BENCH" plan-check) || fail "the corrected plan must pass plan-check: $out"
assert_contains "$out" "BENCH_RESULT plan-check ok" "corrected plan passes"
assert_contains "$out" "6 distinct frozen packets, one sample each" "packets are distinct, not repeated runs"
assert_contains "$out" "a standing route needs 6/6" "the sweep rule is the promotion bar"
pass "a plan carrying the whole correction set passes plan-check"

# Each refusal below is one correction the review demanded, proven to bite.
refuses() {  # <label> <mutation> <expected fragment>
  local label=$1 mutation=$2 expected=$3 bench="$TMP_ROOT/refuse-$$-$RANDOM"
  write_plan "$bench" "$mutation"
  local output status
  output=$(run_gate "$bench" plan-check) && status=0 || status=$?
  expect_code 1 "$status" "$label must refuse"
  assert_contains "$output" "$expected" "$label"
  rm -rf "$bench"
}

refuses "three packets run twice is not six samples" \
  'plan["tracks"]["A"]["packets"] = [{"id": f"A{i%3+1}", "kind": "synthetic"} for i in range(6)]' \
  "six distinct packets"
refuses "a 5-of-6 threshold" \
  'plan["promotion_rule"]["required_wins"] = 5' \
  "5/6 and 4/6+margin are refused"
refuses "an adaptive ninth sample" \
  'plan["adaptive_extension"] = True' \
  "no standing route"
refuses "an optional-stopping extension key" \
  'plan["promotion_rule"]["adaptive_extension_runs"] = 3' \
  "optional-stopping keys"
refuses "a baseline treated as a competing peer" \
  'plan["promotion_rule"]["baseline_role"] = "competitor"' \
  "regression_veto"
refuses "an unstratified baseline subset" \
  'plan["tracks"]["A"]["baseline_packets"] = ["A1", "A2", "A3"]' \
  "preregistered stratified subset"
refuses "a judge whose family fields an entrant" \
  'plan["tracks"]["A"]["judges"] = [{"name": "Terra", "family": "openai"}, {"name": "GLM", "family": "zai"}]' \
  "judge families also field candidates here"
refuses "candidate-specific judge exclusions" \
  'plan["tracks"]["A"]["judge_exclusions"] = {"Fable 5 High": ["GLM 5.3 Max"]}' \
  "candidate-specific judge selection is refused"
refuses "a one-judge panel" \
  'plan["tracks"]["A"]["judges"] = [{"name": "GLM 5.3 Max", "family": "zai"}]' \
  "at least two common neutral-family judges"
refuses "the design author also judging its own specification" \
  'plan["tracks"]["B"]["judges"] = [{"name": "Fable 5", "family": "anthropic"}, {"name": "Nova 3", "family": "cohere"}]' \
  "may not interpret its own unstated intent"
refuses "an unaudited specification" \
  'plan["tracks"]["B"]["spec_audit"][2]["pre_freeze"] = False' \
  "not independent, pre-freeze, or accepted"
refuses "cost in the tie rule" \
  'plan["promotion_rule"]["tie_breakers"] = ["deterministic_evidence", "lower_cost_usd"]' \
  "may not use cost or elapsed time"
refuses "an infrastructure failure that scores instead of voiding" \
  'plan["failure_policy"]["provider_outage"] = "score_zero"' \
  "failure_policy is wrong for"
refuses "cooperative rather than enforced isolation" \
  'plan["isolation_mode"] = "cooperative"' \
  "isolation_mode must be 'enforced'"
refuses "a candidate that may ship directly" \
  'plan["direct_ship"] = True' \
  "archive-then-discard"
refuses "a partial wave on the capture track" \
  'plan["tracks"]["B"]["wave"] = "cursor-entrants-deferred"' \
  "no partial field may start"
refuses "an entrant with no pinned effort" \
  'plan["tracks"]["A"]["entrants"][0]["effort"] = None' \
  "pins no effort"
refuses "an outcome-dependent implementation probe" \
  'plan["tracks"]["A"]["optional_probe"] = "A2 only"' \
  "preregistered for all samples"
pass "every refused plan names the correction it violates"

# --- positive provenance before a historical replay -------------------------

BENCH="$TMP_ROOT/prov"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 absent
out=$(run_gate "$BENCH" provenance-check) && status=0 || status=$?
expect_code 3 "$status" "an unclearable historical packet is a captain call"
assert_contains "$out" "BENCH_CHECK provenance.A1 ok" "a positively identified packet clears"
assert_contains "$out" "missing model_id/family/session_id" "an absent record never clears a replay"
assert_contains "$out" "never a substitution" "a replacement packet stays a captain call"
pass "provenance clears only on positive identification, and failing both is a captain call"

BENCH="$TMP_ROOT/prov-contaminated"
write_plan "$BENCH"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
bench = Path(sys.argv[1])
(bench / "provenance").mkdir(exist_ok=True)
for packet in ("A1", "C1"):
    (bench / "provenance" / f"{packet}.json").write_text(json.dumps({
        "schema": "fm-bench-provenance.v1", "packet": packet, "source": "history",
        "checked_families": ["anthropic", "openai"],
        "participants": [{"task_id": f"{packet}-a", "role": "author",
                          "model_id": "claude-fable-5", "family": "anthropic",
                          "session_id": "cc-1"}]}, indent=2) + "\n")
PY
out=$(run_gate "$BENCH" provenance-check) && status=0 || status=$?
expect_code 3 "$status" "entrant-family exposure blocks the replay"
assert_contains "$out" "entrant-family exposure found" "family exposure is caught, not only exact ids"
pass "family-level exposure blocks a historical replay"

# --- the derived run, cost, and allowance manifest --------------------------

BENCH="$TMP_ROOT/manifest"
write_plan "$BENCH"
out=$(run_gate "$BENCH" manifest-build) || fail "manifest-build must succeed: $out"
assert_contains "$out" "66 model jobs" "the manifest derives 66 total model jobs"
totals=$(python3 -c "
import json,sys; m=json.load(open(sys.argv[1]))['totals']
print(m['scored_outputs'], m['spec_jobs'], m['capture_records'], m['judge_calls'])
" "$BENCH/manifest.json")
[ "$totals" = "60 6 30 120" ] || fail "expected '60 6 30 120' scored/spec/capture/judge, got '$totals'"
pass "the manifest derives 60 scored outputs, 6 specs, and 30 Track B captures from the plan"

out=$(run_gate "$BENCH" manifest-check) && status=0 || status=$?
expect_code 1 "$status" "a metered field with no measured allowance is refused"
assert_contains "$out" "may not start unproven" "the metered field needs a measured allowance"

cat > "$BENCH/allowance.json" <<'EOF'
{"schema":"fm-bench-allowance.v1","providers":{"cursor":{
 "required_runs":12,"reserve_runs":3,"measured_available_runs":13,
 "measured_at":"2026-09-02T09:00:00Z","source":"quota-axi",
 "concurrency_proof":{"tuples":["cursor/composer-2.5","cursor/cursor-grok-4.6-high"],
  "concurrent_sessions":2,"used_benchmark_packet":false,"verified_at":"2026-09-02T09:10:00Z"},
 "full_field_start_proof":{"entrants":5,"verified_at":"2026-09-02T09:20:00Z"}}}}
EOF
out=$(run_gate "$BENCH" manifest-check) && status=0 || status=$?
expect_code 1 "$status" "an allowance that misses the reserve is refused"
assert_contains "$out" "plus the 3-run reserve" "the reserve is part of the allowance bar"

python3 - "$BENCH/allowance.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["providers"]["cursor"]["measured_available_runs"] = 20
json.dump(d, open(p, "w"), indent=2)
PY
out=$(run_gate "$BENCH" manifest-check) || fail "a proven allowance must pass: $out"
assert_contains "$out" "the complete 5-entrant field proven" "the whole field must be provably startable"
pass "the allowance gate needs measured runs, a reserve, real concurrency, and the whole field"

python3 - "$BENCH/allowance.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["providers"]["cursor"]["concurrency_proof"]["used_benchmark_packet"] = True
json.dump(d, open(p, "w"), indent=2)
PY
out=$(run_gate "$BENCH" manifest-check) && status=0 || status=$?
expect_code 1 "$status" "a concurrency proof may not burn a benchmark packet"
assert_contains "$out" "may not consume a benchmark packet" "the concurrency proof stays off the packets"
pass "the concurrency proof may not consume a benchmark packet"

BENCH="$TMP_ROOT/cost-stop"
write_plan "$BENCH" 'plan["approved_cost_class_usd"] = 400.0'
run_gate "$BENCH" manifest-build >/dev/null
out=$(run_gate "$BENCH" manifest-check) && status=0 || status=$?
expect_code 3 "$status" "a high case above the approved class is a captain call"
assert_contains "$out" "never a silent budget expansion" "the budget may not quietly expand"
pass "a measured high cost above the approved class stops for the captain"

BENCH="$TMP_ROOT/manifest-stale"
write_plan "$BENCH"
run_gate "$BENCH" manifest-build >/dev/null
write_plan "$BENCH" 'plan["tracks"]["A"]["entrants"].pop()'
out=$(run_gate "$BENCH" manifest-check) && status=0 || status=$?
expect_code 1 "$status" "a manifest from an older plan is refused"
assert_contains "$out" "generated from a different plan" "the manifest is bound to the plan"
pass "a manifest built from a different plan is refused"

# --- the reproducible, calibrated evaluator ---------------------------------

write_evaluator() {  # <bench-dir> [captures]
  local bench=$1 captures=${2:-30} e="$1/evaluator"
  mkdir -p "$e/determinism" "$e/mutations" "$e/captures"
  cat > "$e/lock.json" <<'EOF'
{"browser":"chromium","browser_version":"141.0.7390.54","playwright_version":"1.58.2",
 "fonts":["Inter 4.0"],"locale":"en-CA","timezone":"UTC",
 "rendering_flags":["--force-color-profile=srgb","--font-render-hinting=none"],
 "viewports":[{"w":1280,"h":900},{"w":768,"h":1024},{"w":390,"h":844}],
 "fixtures":"packets/fixtures@sha256:0f1e","network_mock":"har:packets/net.har",
 "animations":"disabled","color_scheme":"light",
 "readiness_predicate":"networkidle + fonts.ready + 2 stable frames",
 "device_scale_factor":2,
 "zoom_intervention":{"mechanism":"root_font_size_scaling","percent":200,
  "standard":"WCAG 1.4.4 resize text"}}
EOF
  cat > "$e/score-map.json" <<'EOF'
{"pixel_mismatch_to_points":[[0.0,15],[0.02,8],[1.0,0]],
 "region_masks":["[data-testid=clock]"],"anti_alias_tolerance":0.1,
 "axe_severity_to_points":{"critical":0,"serious":5,"none":15},
 "test_result_to_points":{"all_pass":15,"many_fail":0},
 "infrastructure_failure_treatment":"void and rerun capture; never a candidate score",
 "dimension_weights":{"fidelity":17,"pixel_accuracy":17,"responsive":11,"zoom_200":11,
  "accessibility":17,"interaction_states":11,"behavioural_correctness":16,
  "screenshot_completeness":0,"evaluator_success":0,"tree_binding":0}}
EOF
  printf '{"golden_head":"deadbeef","pixel":0.0031,"axe":0}\n' > "$e/determinism/run-1.json"
  cp "$e/determinism/run-1.json" "$e/determinism/run-2.json"
  local dim
  for dim in fidelity pixel_accuracy responsive zoom_200 accessibility \
             interaction_states behavioural_correctness; do
    python3 - "$e/mutations/$dim.json" "$dim" <<'PY'
import json, sys
path, dim = sys.argv[1], sys.argv[2]
names = ["fidelity", "pixel_accuracy", "responsive", "zoom_200", "accessibility",
         "interaction_states", "behavioural_correctness"]
deltas = {name: 0.0 for name in names}
deltas[dim] = -6.0
json.dump({"dimension": dim, "movement_threshold": 1.0, "dimension_deltas": deltas},
          open(path, "w"), indent=2, sort_keys=True)
PY
  done
  python3 - "$e/captures" "$captures" <<'PY'
import hashlib, json, sys
from pathlib import Path
out, want = Path(sys.argv[1]), int(sys.argv[2])
entrants = ["GLM 5.3 Flash", "Grok 4.6", "Composer 2.5", "Terra 5.6 High", "Opus 4.8 High"]
written = 0
for entrant in entrants:
    for index in range(1, 7):
        if written >= want:
            break
        seed = f"{entrant}-B{index}".encode()
        tree = hashlib.sha1(seed).hexdigest()
        slug = entrant.lower().replace(" ", "-").replace(".", "-")
        (out / f"{slug}-b{index}.json").write_text(json.dumps({
            "entrant": entrant, "packet": f"B{index}",
            "original_sha": hashlib.sha1(seed + b"o").hexdigest(), "original_tree": tree,
            "neutral_sha": hashlib.sha1(seed + b"n").hexdigest(), "neutral_tree": tree,
            "base_tree": hashlib.sha1(b"base").hexdigest(),
            "patch_hash": hashlib.sha256(seed).hexdigest(),
            "result_hash": hashlib.sha256(seed + b"r").hexdigest()}, indent=2, sort_keys=True) + "\n")
        written += 1
PY
}

BENCH="$TMP_ROOT/evaluator"
write_plan "$BENCH"
write_evaluator "$BENCH"
out=$(run_gate "$BENCH" evaluator-verify) || fail "the calibrated evaluator must pass: $out"
assert_contains "$out" "30 capture records, one per candidate head" "one bound record per Track B head"
assert_contains "$out" "separate from screenshot resolution" "200% zoom is not deviceScaleFactor"
assert_contains "$out" "evidence-validity conditions carry zero score weight" "validity gates do not score"
pass "the frozen, calibrated evaluator passes with 30 bound capture records"

BENCH="$TMP_ROOT/evaluator-nine"
write_plan "$BENCH"
write_evaluator "$BENCH" 9
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "nine capture jobs cannot cover 30 candidate heads"
assert_contains "$out" "expected 30 capture records" "the capture count is derived, not asserted"
pass "nine capture jobs are refused for thirty candidate heads"

BENCH="$TMP_ROOT/evaluator-drift"
write_plan "$BENCH"
write_evaluator "$BENCH"
printf '{"golden_head":"deadbeef","pixel":0.0074,"axe":1}\n' > "$BENCH/evaluator/determinism/run-2.json"
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "two differing dry-runs are not a deterministic evaluator"
assert_contains "$out" "no preregistered bounded delta" "an unexplained rerun difference is refused"
pass "an evaluator whose two dry-runs disagree is refused"

BENCH="$TMP_ROOT/evaluator-bleed"
write_plan "$BENCH"
write_evaluator "$BENCH"
python3 - "$BENCH/evaluator/mutations/zoom_200.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["dimension_deltas"]["accessibility"] = -4.0
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "a mutation that moves unrelated dimensions is refused"
assert_contains "$out" "unrelated dimensions moved with zoom_200" "dimensions must be separable"
pass "a mutation that bleeds into unrelated dimensions is refused"

BENCH="$TMP_ROOT/evaluator-zero-threshold"
write_plan "$BENCH"
write_evaluator "$BENCH"
python3 - "$BENCH/evaluator/mutations/zoom_200.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["movement_threshold"] = 0
d["dimension_deltas"]["zoom_200"] = 0
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "a zero mutation threshold may not calibrate a zero delta"
assert_contains "$out" "dimension, dimension_deltas, and movement_threshold" "a calibration threshold must be positive"
pass "a zero mutation threshold cannot create a calibration pass"

BENCH="$TMP_ROOT/evaluator-uncalibrated"
write_plan "$BENCH"
write_evaluator "$BENCH"
rm -f "$BENCH/evaluator/mutations/accessibility.json" "$BENCH/evaluator/mutations/responsive.json"
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "one calibrated dimension does not calibrate a seven-dimension score map"
assert_contains "$out" "never proven to respond to their own mutation" "every scored dimension must be calibrated"
assert_contains "$out" "accessibility, responsive" "the refusal names the uncalibrated dimensions"
pass "a scored dimension with no mutation record is refused"

BENCH="$TMP_ROOT/evaluator-capture-scope"
write_plan "$BENCH"
write_evaluator "$BENCH"
python3 - "$BENCH/evaluator/captures" <<'PY'
import json, sys
from pathlib import Path
p = sorted(Path(sys.argv[1]).glob("*.json"))[0]
d = json.loads(p.read_text()); d["packet"] = "B7"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "capture records must exactly cover planned candidate heads"
assert_contains "$out" "missing Composer 2.5 on B1" "the missing planned capture is named"
assert_contains "$out" "unexpected Composer 2.5 on B7" "the unexpected capture is named"
pass "capture records outside the planned candidate heads are refused"

BENCH="$TMP_ROOT/evaluator-scored-gate"
write_plan "$BENCH"
write_evaluator "$BENCH"
python3 - "$BENCH/evaluator/score-map.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["dimension_weights"]["screenshot_completeness"] = 10
d["dimension_weights"]["behavioural_correctness"] = 6
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "producing mandatory evidence may not score candidate quality"
assert_contains "$out" "validity conditions still score candidate quality" "the 10-point evidence gate is removed"
pass "scoring a candidate for the evaluator producing its own evidence is refused"

BENCH="$TMP_ROOT/evaluator-rewritten"
write_plan "$BENCH"
write_evaluator "$BENCH"
python3 - "$BENCH/evaluator/captures" <<'PY'
import json, sys
from pathlib import Path
p = sorted(Path(sys.argv[1]).glob("*.json"))[0]
d = json.loads(p.read_text()); d["neutral_tree"] = "0" * 40
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "a capture whose neutralisation changed the tree is refused"
assert_contains "$out" "capture and judging would bind different objects" "tree identity binds capture to judging"
pass "neutralisation that changes the judged tree is refused"

# --- freeze before labels, and the launch guard that binds to it ------------

BENCH="$TMP_ROOT/freeze"
write_plan "$BENCH"
mkdir -p "$BENCH/packets/A1" "$BENCH/ground-truth" "$BENCH/scoring" "$BENCH/judge-prompts"
printf 'packet text\n' > "$BENCH/packets/A1/packet.md"
printf 'sealed truth\n' > "$BENCH/ground-truth/A1.md"
printf 'score()\n' > "$BENCH/scoring/composite.py"
printf 'judge prompt\n' > "$BENCH/judge-prompts/track-a.md"
out=$(run_gate "$BENCH" freeze) || fail "freeze must succeed before labels exist: $out"
out=$(run_gate "$BENCH" freeze-check) || fail "a fresh freeze must verify: $out"
printf 'edited truth\n' > "$BENCH/ground-truth/A1.md"
out=$(run_gate "$BENCH" freeze-check) && status=0 || status=$?
expect_code 1 "$status" "ground truth edited after the freeze is refused"
assert_contains "$out" "changed after the freeze" "the freeze binds the sealed inputs"
pass "the freeze binds packets, ground truth, scoring, prompts, tuples, seed, and failure policy"

BENCH="$TMP_ROOT/freeze-late"
write_plan "$BENCH"
printf '{"K7":"Fable 5 High"}\n' > "$BENCH/key.json"
out=$(run_gate "$BENCH" freeze) && status=0 || status=$?
expect_code 1 "$status" "freezing after labels exist is refused"
assert_contains "$out" "must precede label assignment" "labels may not be assigned before the freeze"
pass "a freeze attempted after labels are assigned is refused"

# --- the fail-closed launch guard -------------------------------------------

guard() {  # <task-id> [bench-dir]
  local id=$1 bench=${2:-}
  (
    unset FM_BENCH_ROOT FM_BENCH_LAUNCH_BYPASS
    [ -z "$bench" ] || export FM_BENCH_ROOT="$bench"
    # shellcheck source=bin/fm-bench-launch-lib.sh
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-bench-launch-lib.sh"
    fm_refuse_ungated_benchmark_entrant "$id" 2>&1
    printf 'rc=%s\n' "$?"
  )
}

out=$(guard "ordinary-crew-task")
assert_contains "$out" "rc=0" "an ordinary task id is untouched by the benchmark guard"
out=$(guard "bench-b1-k7")
assert_contains "$out" "rc=1" "a benchmark entrant with no benchmark directory is refused"
assert_contains "$out" "no benchmark directory" "the refusal names the missing requirement"
pass "the launch guard scopes to benchmark ids and otherwise stays out of the way"

BENCH="$TMP_ROOT/launch-confinement"
ENTRY_ROOT="$BENCH/entrant"
ENTRY_HOME="$ENTRY_ROOT/home with space"
write_plan "$BENCH"
mkdir -p "$ENTRY_ROOT/objects" "$ENTRY_ROOT/tmp" "$ENTRY_HOME" "$ENTRY_ROOT/session"
python3 - "$BENCH" "$ROOT/bin/fm-bench-confine.sh" "$ENTRY_ROOT" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench, confine, entrant = Path(sys.argv[1]), sys.argv[2], Path(sys.argv[3])
(bench / "isolation.json").write_text(json.dumps({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [confine, "--mechanism", "none", "--allow", "{root}", "--"],
    "entrants": [{"id": "bench-b1-k7", "root": str(entrant),
                  "private_object_store": str(entrant / "objects"),
                  "private_tmp": str(entrant / "tmp"),
                  "private_home": str(entrant / "home with space"),
                  "private_session": str(entrant / "session")}],
}, indent=2, sort_keys=True) + "\n")
digest = hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest()
isolation_digest = hashlib.sha256((bench / "isolation.json").read_bytes()).hexdigest()
(bench / "preflight.receipt").write_text(json.dumps({
    "schema": "fm-bench-preflight-receipt.v1", "verdict": "pass", "plan_sha256": digest,
    "isolation_sha256": isolation_digest,
}, indent=2, sort_keys=True) + "\n")
PY
out=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch ordinary-crew-task "$2" "printf untouched"
' _ "$ROOT" "$ENTRY_ROOT") || fail "ordinary launch preparation must be untouched: $out"
[ "$out" = "printf untouched" ] || fail "ordinary launch preparation changed the launch command"
wrapped=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch bench-b1-k7 "$2" "printf \"%s|%s|%s\" \"\$BENCH_PRIVATE_ROOT\" \"\$BENCH_PRIVATE_HOME\" \"\$BENCH_PRIVATE_TMP\""
' _ "$ROOT" "$ENTRY_ROOT") || fail "a benchmark launch must bind the proven confinement"
out=$(bash -c "$wrapped") || fail "the bound benchmark launch must execute: $out"
assert_contains "$out" "$ENTRY_ROOT|$ENTRY_HOME|$ENTRY_ROOT/tmp" "the proven private root, home, and temp reach the entrant"
python3 - "$BENCH/isolation.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["leak_marker"] = "FM_BENCH_CHANGED_"
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
out=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch bench-b1-k7 "$2" "printf unsafe"
' _ "$ROOT" "$ENTRY_ROOT" 2>&1) && status=0 || status=$?
expect_code 1 "$status" "a launch may not use an isolation layout changed after preflight"
assert_contains "$out" "does not cover the current isolation layout" "the preflight binds the isolation layout"
python3 - "$BENCH/isolation.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["exec_wrapper"][0] = "/missing/benchmark-wrapper"
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
receipt = bench / "preflight.receipt"
d = json.loads(receipt.read_text())
d["isolation_sha256"] = hashlib.sha256((bench / "isolation.json").read_bytes()).hexdigest()
receipt.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch bench-b1-k7 "$2" "printf unsafe"
' _ "$ROOT" "$ENTRY_ROOT" 2>&1) && status=0 || status=$?
expect_code 1 "$status" "a benchmark launch with no verified wrapper is refused"
assert_contains "$out" "cannot use its preflight-proven confinement" "the launch refuses rather than falling back unconfined"
pass "benchmark launches bind the preflight-proven confinement while ordinary launches stay unchanged"

out=$(bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_refuse_unconfined_remote_benchmark_entrant ordinary-crew-task 2>&1
  printf "rc=%s\n" "$?"
' _ "$ROOT")
assert_contains "$out" "rc=0" "an ordinary remote secondmate id remains unchanged"
out=$(bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_refuse_unconfined_remote_benchmark_entrant bench-b1-k7 2>&1
  printf "rc=%s\n" "$?"
' _ "$ROOT")
assert_contains "$out" "rc=1" "a benchmark remote secondmate refuses without local confinement"
assert_contains "$out" "remote secondmate route" "the remote confinement refusal names the route"
pass "remote benchmark secondmate launches fail closed instead of bypassing confinement"

BENCH="$TMP_ROOT/launch"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
write_evaluator "$BENCH"
run_gate "$BENCH" manifest-build >/dev/null
cat > "$BENCH/allowance.json" <<'EOF'
{"schema":"fm-bench-allowance.v1","providers":{"cursor":{
 "required_runs":12,"reserve_runs":3,"measured_available_runs":20,
 "measured_at":"2026-09-02T09:00:00Z","source":"quota-axi",
 "concurrency_proof":{"tuples":["cursor/composer-2.5","cursor/cursor-grok-4.6-high"],
  "concurrent_sessions":2,"used_benchmark_packet":false,"verified_at":"2026-09-02T09:10:00Z"},
 "full_field_start_proof":{"entrants":5,"verified_at":"2026-09-02T09:20:00Z"}}}}
EOF
run_gate "$BENCH" freeze >/dev/null
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "an entrant with no passing preflight is refused"
assert_contains "$out" "no passing preflight" "the refusal names the missing preflight"

# A hand-written receipt cannot substitute for a real pass: it is bound to the
# plan's bytes, so it survives only while the plan it cleared is unchanged.
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
digest = hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest()
(bench / "preflight.receipt").write_text(json.dumps({
    "schema": "fm-bench-preflight-receipt.v1", "verdict": "pass",
    "plan_sha256": digest, "stages": ["plan"]}, indent=2) + "\n")
PY
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=0" "a receipt bound to the current plan permits the launch"
write_plan "$BENCH" 'plan["promotion_rule"]["required_wins"] = 4'
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "a plan relaxed after the pass invalidates the receipt"
assert_contains "$out" "covers a different plan" "the receipt is bound to the plan bytes"
pass "a threshold relaxed after a passing preflight cannot ride the old receipt"

# The receipt binds only the plan's bytes, so evidence degrading outside the
# plan would leave a stale clearance standing. A refusing preflight revokes it.
BENCH="$TMP_ROOT/revoke"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
write_evaluator "$BENCH"
run_gate "$BENCH" manifest-build >/dev/null
run_gate "$BENCH" freeze >/dev/null
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
digest = hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest()
(bench / "preflight.receipt").write_text(json.dumps({
    "schema": "fm-bench-preflight-receipt.v1", "verdict": "pass",
    "plan_sha256": digest, "stages": ["plan"]}, indent=2) + "\n")
PY
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=0" "the clearance stands while it matches the plan"
out=$(run_gate "$BENCH" preflight) && status=0 || status=$?
expect_code 1 "$status" "a preflight without isolation evidence must refuse"
assert_contains "$out" "the prior clearance is revoked" "the refusal reports the revocation"
assert_absent "$BENCH/preflight.receipt" "a refusing preflight removes the receipt it wrote"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "the launch guard refuses once the clearance is revoked"
pass "evidence degrading outside the plan revokes the clearance rather than leaving it standing"

out=$(FM_BENCH_LAUNCH_BYPASS=1 bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_refuse_ungated_benchmark_entrant bench-b1-k7 2>&1
  printf "rc=%s\n" "$?"' _ "$ROOT")
assert_contains "$out" "rc=0" "the documented test-harness hatch works"
pass "the launch guard honours only its documented test-harness hatch"

# --- fm-spawn refuses an ungated benchmark entrant --------------------------

SPAWN_OUT=$( (unset FM_BENCH_ROOT FM_BENCH_LAUNCH_BYPASS
  FM_ROOT_OVERRIDE="$TMP_ROOT/spawnhome" FM_HOME="$TMP_ROOT/spawnhome" \
  FM_STATE_OVERRIDE="$TMP_ROOT/spawnhome/state" \
    "$ROOT/bin/fm-spawn.sh" --mode local-only --yolo off bench-b1-k7 "$TMP_ROOT/repo" 2>&1) ) \
  && spawn_status=0 || spawn_status=$?
[ "$spawn_status" -ne 0 ] || fail "fm-spawn must refuse an ungated benchmark entrant"
assert_contains "$SPAWN_OUT" "launch refused" "fm-spawn refuses the ungated benchmark entrant"
pass "fm-spawn refuses a benchmark entrant that no passing preflight covers"

# --- isolation: the probe set is not vacuous --------------------------------
#
# Full denial needs a real confinement and is proven in
# tests/fm-bench-isolation-e2e.test.sh. What must hold everywhere is that the
# probes really reach a sibling when nothing confines them, that a denial with
# no positive control proves nothing, and that partial confinement earns no
# partial credit.

ISO="$TMP_ROOT/iso"
mkdir -p "$ISO/sealed"
printf 'K7 -> Fable 5 High\n' > "$ISO/sealed/key.json"
for entrant in e1 e2; do
  mkdir -p "$ISO/$entrant/objects" "$ISO/$entrant/tmp" "$ISO/$entrant/home" "$ISO/$entrant/session"
  # Each declared private store is a probe target, so it must hold material a
  # sibling can be proven unable to read; an empty directory proves nothing.
  for private in objects tmp home session; do
    printf 'private %s material for %s\n' "$private" "$entrant" > "$ISO/$entrant/$private/canary.txt"
  done
  fm_git_init_commit "$ISO/$entrant" >/dev/null
  printf 'candidate work %s\n' "$entrant" > "$ISO/$entrant/answer.txt"
  git -C "$ISO/$entrant" add -A
  git -C "$ISO/$entrant" -c user.name=t -c user.email=t@x commit -qm work
  mkdir -p "$ISO/$entrant/.git/worktrees/w"
done

write_isolation() {  # <bench-dir> <mechanism>
  local bench=$1 mechanism=$2
  python3 - "$bench/isolation.json" "$ROOT/bin/fm-bench-confine.sh" "$mechanism" "$ISO" <<'PY'
import json, sys
path, confine, mechanism, iso = sys.argv[1:5]
json.dump({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [confine, "--mechanism", mechanism, "--allow", "{root}", "--"],
    "leak_marker": "FM_BENCH_",
    "protected_paths": [f"{iso}/sealed"],
    "entrants": [
        {"id": f"bench-b1-{label}", "root": f"{iso}/{name}",
         "private_object_store": f"{iso}/{name}/objects",
         "private_tmp": f"{iso}/{name}/tmp",
         "private_home": f"{iso}/{name}/home",
         "private_session": f"{iso}/{name}/session"}
        for label, name in (("k7", "e1"), ("r2", "e2"))],
}, open(path, "w"), indent=2, sort_keys=True)
PY
}

BENCH="$TMP_ROOT/iso-bench"
write_plan "$BENCH"
write_isolation "$BENCH" none
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "unconfined entrants must fail the isolation gate"
for probe in sibling_file_read sibling_worktree_enumeration sibling_object_enumeration \
             sibling_unreachable_objects protected_path_read process_inspection environment_leakage; do
  assert_contains "$out" "isolation.bench-b1-k7.$probe fail" "the $probe probe must detect a real leak"
done
assert_contains "$out" "PROBE LEAKED enumerated shared objects" "shared-object access is detected, not just named paths"
assert_contains "$out" "PROBE LEAKED read sealed material" "the sealed key is reachable without confinement"
# The four declared per-entrant paths are probed, not trusted: a sibling must be
# proven unable to read each of them.
for private in objects tmp home session; do
  assert_contains "$out" "reachable against $ISO/e2/$private" \
    "the sibling's declared private $private is a probe target"
done
pass "all seven sibling-access probes detect a real leak when nothing confines the entrant"

# The process probe must still measure a shared process table when the image
# ships no ps, which is the case for the container image the gate documents.
# Reading /proc must yield one line per process: a single concatenated line
# makes the probe's own self-exclusion delete the whole table and report a
# denial while every host process is readable.
if command -v ps >/dev/null 2>&1; then
  MARKER_FILE="$TMP_ROOT/process-target"
  READY_FILE="$TMP_ROOT/process-ready"
  RELEASE_FILE="$TMP_ROOT/process-release"
  FAKE_BIN="$TMP_ROOT/process-tools"
  PS_BIN=$(command -v ps)
  TR_BIN=$(command -v tr)
  mkdir -p "$FAKE_BIN"
  cat > "$FAKE_BIN/tr" <<'EOF'
#!/usr/bin/env bash
: > "${PROCESS_PROBE_READY_FILE:?}"
while [ ! -e "${PROCESS_PROBE_RELEASE_FILE:?}" ]; do sleep 0.01; done
exec "${PROCESS_PROBE_REAL_TOOL:?}" "$@"
EOF
  cp "$FAKE_BIN/tr" "$FAKE_BIN/ps"
  chmod +x "$FAKE_BIN/tr" "$FAKE_BIN/ps"
  MARKER_VALUE="fm-bench-marker-${RANDOM}-$$"
  printf '%s\n' "$MARKER_VALUE" > "$MARKER_FILE"
  PATH="$FAKE_BIN:$PATH" PROCESS_INSPECTION_MARKER_FILE="$MARKER_FILE" \
    PROCESS_PROBE_READY_FILE="$READY_FILE" PROCESS_PROBE_RELEASE_FILE="$RELEASE_FILE" \
    PROCESS_PROBE_REAL_TOOL="$([ -d /proc/1 ] && printf '%s' "$TR_BIN" || printf '%s' "$PS_BIN")" \
    "$ROOT/bin/fm-bench-probe.sh" process_inspection > "$TMP_ROOT/process.out" &
  probe_pid=$!
  for _ in $(seq 1 100); do [ -e "$READY_FILE" ] && break; sleep 0.01; done
  [ -e "$READY_FILE" ] || fail "the in-flight process probe did not reach its process-table read"
  marker_in_argv=0
  probe_chain=$("$PS_BIN" -A -o pid= -o ppid= | awk -v root="$probe_pid" '
    { parent[$1] = $2 }
    END {
      for (pid in parent) {
        current = pid
        while (current && current != 0 && !seen[current]++) {
          if (current == root) {
            print pid
            break
          }
          current = parent[current]
        }
        delete seen
      }
    }')
  for process_pid in $probe_chain; do
    process_line=$("$PS_BIN" -p "$process_pid" -o args=)
    case "$process_line" in *"$MARKER_VALUE"*) marker_in_argv=1; break ;; esac
  done
  [ "$marker_in_argv" -eq 0 ] || fail "the process-inspection marker reached a gate-owned command line"
  : > "$RELEASE_FILE"
  wait "$probe_pid" || fail "the marker-free in-flight process probe did not finish"
  out=$(cat "$TMP_ROOT/process.out")
  assert_contains "$out" "PROBE DENIED" "the marker-free launch chain denies when no sibling marker process runs"
  MARKER="$TMP_ROOT/$MARKER_VALUE"
  printf '#!/bin/sh\nwhile :; do sleep 1; done\n' > "$MARKER"
  chmod +x "$MARKER"
  "$MARKER" &
  marker_pid=$!
  sleep 1
  out=$(PROCESS_INSPECTION_MARKER_FILE="$MARKER_FILE" "$ROOT/bin/fm-bench-probe.sh" process_inspection)
  kill "$marker_pid" 2>/dev/null
  wait "$marker_pid" 2>/dev/null
  assert_contains "$out" "PROBE LEAKED" "a shared process table is a leak, not a denial"
  pass "the process probe keeps its marker out of the launch chain and separates leaks from denials"
fi

# A declared private path with nothing readable under it cannot carry a denial.
BENCH="$TMP_ROOT/iso-barren"
write_plan "$BENCH"
write_isolation "$BENCH" none
mkdir -p "$ISO/barren"
python3 - "$BENCH/isolation.json" "$ISO/barren" <<'PY'
import json, sys
path, barren = sys.argv[1], sys.argv[2]
d = json.load(open(path))
d["entrants"][0]["private_tmp"] = barren
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "private storage a probe cannot read carries no denial"
assert_contains "$out" "isolation.bench-b1-k7.private_storage fail" "the barren private store is named"
assert_contains "$out" "private_tmp" "the refusal names which declared store is unprovable"
pass "declared private storage that no probe could read is refused, not trusted"

BENCH="$TMP_ROOT/iso-outside-private"
write_plan "$BENCH"
write_isolation "$BENCH" none
mkdir -p "$ISO/outside-private"
printf 'outside private material\n' > "$ISO/outside-private/canary.txt"
python3 - "$BENCH/isolation.json" "$ISO/outside-private" <<'PY'
import json, sys
path, outside = sys.argv[1:]
d = json.load(open(path))
d["entrants"][0]["private_tmp"] = outside
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "private storage outside its entrant root is refused before launch"
assert_contains "$out" "isolation.bench-b1-k7.private_containment fail" "the isolation gate owns private-path containment"
assert_contains "$out" "private_tmp" "the containment refusal names the offending private path"
pass "private paths outside the proven entrant root are refused during isolation verification"

# An object store reached through .git/objects/info/alternates sits outside every
# entrant root, so a probe that only walks the sibling root would miss it.
BENCH="$TMP_ROOT/iso-alternates"
write_plan "$BENCH"
write_isolation "$BENCH" none
mkdir -p "$ISO/shared-objects" "$ISO/e1/.git/objects/info"
printf 'shared object bytes\n' > "$ISO/shared-objects/canary"
printf '%s\n' "$ISO/shared-objects" > "$ISO/e1/.git/objects/info/alternates"
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
rm -f "$ISO/e1/.git/objects/info/alternates"
expect_code 1 "$status" "an alternate object store outside the entrant's storage is refused"
assert_contains "$out" "isolation.bench-b1-k7.alternates fail" "the escaping alternate is named"
assert_contains "$out" "objects/info/alternates" "the refusal names the vector"
assert_contains "$out" "reachable against $ISO/shared-objects" \
  "the alternate object store is probed as a sibling target"
pass "an object store reachable through git alternates is caught rather than missed"

# A confinement that scrubs the environment but leaves the filesystem shared
# earns credit for exactly one probe and still fails the gate.
BENCH="$TMP_ROOT/iso-partial"
write_plan "$BENCH"
python3 - "$BENCH/isolation.json" "$TMP_ROOT/env-only.sh" "$ISO" <<'PY'
import json, os, stat, sys
path, wrapper, iso = sys.argv[1:4]
with open(wrapper, "w") as handle:
    handle.write('#!/usr/bin/env bash\nexec env -i PATH="$PATH" HOME="$HOME" "$@"\n')
os.chmod(wrapper, os.stat(wrapper).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
json.dump({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [wrapper],
    "leak_marker": "FM_BENCH_",
    "protected_paths": [f"{iso}/sealed"],
    "entrants": [
        {"id": f"bench-b1-{label}", "root": f"{iso}/{name}",
         "private_object_store": f"{iso}/{name}/objects",
         "private_tmp": f"{iso}/{name}/tmp",
         "private_home": f"{iso}/{name}/home",
         "private_session": f"{iso}/{name}/session"}
        for label, name in (("k7", "e1"), ("r2", "e2"))],
}, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "partial confinement earns no partial credit"
assert_contains "$out" "isolation.bench-b1-k7.environment_leakage ok" "the environment probe really flips to denied"
assert_contains "$out" "isolation.bench-b1-k7.sibling_file_read fail" "shared filesystem access still refuses the gate"
pass "per-probe verdicts are real, and partial confinement still refuses the launch"

# A target that does not exist would report "denied" for the wrong reason.
BENCH="$TMP_ROOT/iso-control"
write_plan "$BENCH"
write_isolation "$BENCH" none
python3 - "$BENCH/isolation.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["protected_paths"] = ["/nonexistent/sealed/material"]
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "a probe with no positive control is refused"
assert_contains "$out" "no positive control" "a denial against an absent target proves nothing"
pass "a denial with no positive control is refused rather than counted as isolation"

BENCH="$TMP_ROOT/iso-missing"
write_plan "$BENCH"
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "enforced isolation must be provisioned before launch"
assert_contains "$out" "must be provisioned and proven" "an unprovisioned benchmark cannot launch"
pass "an unprovisioned benchmark is refused before any entrant launches"

# --- archive, restore drill, and the cleanup authority ----------------------

write_archive() {  # <bench-dir> <src-repo>
  local bench=$1 src=$2
  python3 - "$bench" "$src" <<'PY'
import hashlib, json, shutil, subprocess, sys
from pathlib import Path

bench, src = Path(sys.argv[1]), Path(sys.argv[2])
plan = json.loads((bench / "benchmark.json").read_text())
shutil.rmtree(src, ignore_errors=True)
src.mkdir(parents=True)
env = {"PATH": "/usr/bin:/bin:/usr/local/bin", "HOME": str(src),
       "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x",
       "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"}


def git(*args):
    return subprocess.run(["git", *args], cwd=src, check=True, env=env,
                          stdout=subprocess.PIPE).stdout.decode().strip()


git("init", "-q", ".")
git("commit", "-q", "--allow-empty", "-m", "base")
base_tree = git("rev-parse", "HEAD^{tree}")

work = []
for name in sorted(plan["tracks"]):
    track = plan["tracks"][name]
    ids = [packet["id"] for packet in track["packets"]]
    for entrant in track["entrants"]:
        work.extend((name, entrant["name"], pid) for pid in ids)
    if "baseline" in track:
        work.extend((name, track["baseline"]["name"], pid) for pid in track["baseline_packets"])

root = bench / "archive"
shutil.rmtree(root, ignore_errors=True)
for track_name, candidate, packet in work:
    slug = f"{track_name}-{packet}-{candidate}".lower().replace(" ", "-").replace(".", "-")
    (src / "work.txt").write_text(slug + "\n")
    git("add", "-A")
    git("commit", "-q", "-m", slug)
    sha, tree = git("rev-parse", "HEAD"), git("rev-parse", "HEAD^{tree}")
    out = root / slug
    out.mkdir(parents=True)
    git("bundle", "create", "-q", str(out / "candidate.bundle"), "HEAD")
    files = {}

    def put(name, text):
        (out / name).write_text(text)
        files[name] = hashlib.sha256((out / name).read_bytes()).hexdigest()

    put("packet.md", f"packet {packet}\n")
    put("ground-truth.md", "sealed truth\n")
    put("projection.diff", f"neutral projection for {slug}\n")
    put("transcript.md", "redacted transcript\n")
    put("capture.json", '{"pixel":0.003}\n')
    scoring = """#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path

tree = Path(sys.argv[1])
payload = {"candidate_sha256": hashlib.sha256((tree / "work.txt").read_bytes()).hexdigest(), "pixel": 0.003}
print(json.dumps(payload, sort_keys=True))
"""
    put("scoring.py", scoring)
    (out / "scoring.py").chmod(0o755)
    put("judging.json", '{"raw":[8,9],"order":["k7","r2"]}\n')
    put("timing.json", '{"operational_s":1200,"session_s":1100}\n')
    put("verdict.md", "label K7 -> candidate\n")
    files["candidate.bundle"] = hashlib.sha256((out / "candidate.bundle").read_bytes()).hexdigest()
    (out / "manifest.json").write_text(json.dumps({
        "schema": "fm-bench-archive.v1", "sample": slug,
        "groups": {
            "packet_and_ground_truth": ["packet.md", "ground-truth.md"],
            "candidate_bundle_and_projection": ["candidate.bundle", "projection.diff"],
            "tree_binding": ["capture.json"], "transcript": ["transcript.md"],
            "capture_and_scoring": ["capture.json", "scoring.py"],
            "judging": ["judging.json"], "timing_cost_quota": ["timing.json"],
            "key_and_verdict": ["verdict.md"]},
        "files": files,
        "tree_binding": {"original_sha": sha, "original_tree": tree, "neutral_sha": sha,
                         "neutral_tree": tree, "base_tree": base_tree,
                         "patch_hash": hashlib.sha256(slug.encode()).hexdigest()},
        "evaluator_rerun": {"argv": ["scoring.py"],
                             "result_hash": hashlib.sha256((json.dumps({"candidate_sha256": hashlib.sha256((slug + "\n").encode()).hexdigest(), "pixel": 0.003}, sort_keys=True) + "\n").encode()).hexdigest()},
    }, indent=2, sort_keys=True) + "\n")
PY
}

BENCH="$TMP_ROOT/archive"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo"
out=$(run_gate "$BENCH" archive-verify) || fail "the complete archive must verify: $out"
assert_contains "$out" "8 evidence groups" "every archive carries all eight evidence groups"
pass "one content-addressed archive per scored output verifies against its stored bytes"

out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "cleanup before a restore drill is refused"
assert_contains "$out" "cleanup stays refused" "cleanup needs a drill first"
pass "candidate and snapshot cleanup is refused until a restore drill passes"

out=$(run_gate "$BENCH" restore-drill) || fail "the restore drill must pass: $out"
assert_contains "$out" "restored into a fresh repository, and rebound to its archived tree" \
  "each bundle is really restored and rebound"
assert_present "$BENCH/archive/restore-drill.json" "the drill writes its receipt"
out=$(run_gate "$BENCH" cleanup-gate) || fail "cleanup must pass after a drill: $out"
assert_contains "$out" "no candidate ships directly" "the disposition is re-asserted at cleanup"
pass "the restore drill authorises cleanup only after really restoring every bundle"

BENCH="$TMP_ROOT/archive-binding"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-binding"
run_gate "$BENCH" restore-drill >/dev/null || fail "the archive binding fixture must drill successfully"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text()); d["tree_binding"]["base_tree"] = "f" * 40
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "editing a manifest binding after a drill withdraws cleanup"
assert_contains "$out" "changed after the restore drill" "the receipt binds manifest bytes as well as evidence files"
pass "a changed archive manifest withdraws the prior cleanup authority"

archive_escape_refused() {  # <label> <path-kind>
  local label=$1 kind=$2 bench
  bench="$TMP_ROOT/archive-escape-$kind"
  write_plan "$bench"
  write_archive "$bench" "$TMP_ROOT/srcrepo-escape-$kind"
  python3 - "$bench" "$kind" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
bench, kind = Path(sys.argv[1]), sys.argv[2]
sample = sorted((bench / "archive").iterdir())[0]
external = bench / "external.bundle"
external.write_bytes((sample / "candidate.bundle").read_bytes())
(sample / "candidate.bundle").unlink()
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
if kind == "absolute":
    name = str(external)
elif kind == "parent":
    target = sample.parent / "external.bundle"
    target.write_bytes(external.read_bytes())
    name = "../external.bundle"
else:
    name = "escape.bundle"
    (sample / name).symlink_to(external)
record["files"].pop("candidate.bundle")
record["files"][name] = hashlib.sha256(external.read_bytes()).hexdigest()
record["groups"]["candidate_bundle_and_projection"] = [name, "projection.diff"]
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
  out=$(run_gate "$bench" archive-verify) && status=0 || status=$?
  expect_code 1 "$status" "$label archive path is refused"
  assert_contains "$out" "escapes sample archive" "$label path is kept inside its own sample archive"
}

archive_escape_refused "an absolute" absolute
archive_escape_refused "a parent traversal" parent
archive_escape_refused "a symlink" symlink
pass "external archive evidence paths cannot make an archive self-contained only by declaration"

BENCH="$TMP_ROOT/archive-unlisted"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-unlisted"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
(sample / "unlisted-evidence.txt").write_text("not addressed\n")
PY
out=$(run_gate "$BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "an archive evidence file without a content address is refused"
assert_contains "$out" "archive files are not content-addressed" "the archive rejects unlisted evidence"
pass "every archived evidence file is content-addressed"

BENCH="$TMP_ROOT/archive-nested-manifest"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-nested-manifest"
python3 - "$BENCH" <<'PY'
import sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
(sample / ".evidence").mkdir()
(sample / ".evidence" / "manifest.json").write_text("not addressed\n")
PY
out=$(run_gate "$BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "a nested manifest-named evidence file without a content address is refused"
assert_contains "$out" ".evidence/manifest.json" "the archive addresses nested manifest-named evidence by path"
pass "only the sample manifest itself is exempt from content addressing"

BENCH="$TMP_ROOT/archive-unlisted-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-unlisted-evaluator"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["evaluator_rerun"]["argv"] = ["unlisted-evaluator.py"]
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a rerun evaluator absent from the content-addressed files is refused"
assert_contains "$out" "not content-addressed" "the drill requires the executed evaluator to be addressed"
assert_absent "$BENCH/archive/restore-drill.json" "an unaddressed evaluator writes no cleanup receipt"
pass "the restore drill executes only a content-addressed evaluator"

BENCH="$TMP_ROOT/archive-noop-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-noop-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
(sample / "scoring.sh").write_text("#!/bin/sh\ncat capture.json\n")
(sample / "scoring.sh").chmod(0o755)
record["files"]["scoring.sh"] = hashlib.sha256((sample / "scoring.sh").read_bytes()).hexdigest()
record["groups"]["capture_and_scoring"] = ["capture.json", "scoring.sh"]
record["evaluator_rerun"] = {"argv": ["scoring.sh"], "result_hash": hashlib.sha256((sample / "capture.json").read_bytes()).hexdigest()}
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an archived-file echo cannot stand in for a restored-tree evaluator"
assert_contains "$out" "invariant under a perturbed restored candidate" "the rerun contract proves evaluator dependence on restored content"
assert_absent "$BENCH/archive/restore-drill.json" "a no-op evaluator writes no cleanup receipt"
pass "the restore drill refuses an executable evaluator that ignores restored content"

BENCH="$TMP_ROOT/archive-scratch-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-scratch-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/usr/bin/env python3
import hashlib
import json
import sys
from pathlib import Path

Path('scratch-only.txt').write_text('scratch\\n')
tree = Path(sys.argv[1])
payload = {"candidate_sha256": hashlib.sha256((tree / "work.txt").read_bytes()).hexdigest(), "pixel": 0.003, "scratch_marker": Path("scratch-only.txt").read_text().strip()}
print(json.dumps(payload, sort_keys=True))
""")
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256((json.dumps({"candidate_sha256": hashlib.sha256((record["sample"] + "\n").encode()).hexdigest(), "pixel": 0.003, "scratch_marker": "scratch"}, sort_keys=True) + "\n").encode()).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) || fail "an evaluator that writes scratch output must not dirty its archive: $out"
assert_contains "$out" "changed perturbed result" "the scratch-writing evaluator ran against both restored candidates"
first_sample=$(find "$BENCH/archive" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
assert_absent "$first_sample/scratch-only.txt" "evaluator scratch output never reaches the certified archive"
out=$(run_gate "$BENCH" cleanup-gate) || fail "a scratch-only evaluator must leave cleanup authorised: $out"
pass "archived evaluators rerun in scratch rather than certified storage"

BENCH="$TMP_ROOT/archive-post-rerun"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-post-rerun"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text(scoring.read_text().replace("tree = Path(sys.argv[1])", f"Path({str(sample / 'archive-dirty.txt')!r}).write_text('dirty\\n')\ntree = Path(sys.argv[1])"))
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an evaluator that changes archive evidence during a drill is refused"
assert_contains "$out" "restore.archive_stability fail" "the drill re-verifies archive bytes after evaluator execution"
assert_absent "$BENCH/archive/restore-drill.json" "a post-rerun archive change writes no cleanup receipt"
pass "post-rerun archive verification catches an evaluator that dirties evidence"

BENCH="$TMP_ROOT/archive-evaluator-drift"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-evaluator-drift"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text()); d["evaluator_rerun"]["result_hash"] = "0" * 64
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a rerun whose archived evaluator result drifts is refused"
assert_contains "$out" "archived evaluator result hash" "the drill executes the evaluator instead of trusting its declared hash"
assert_absent "$BENCH/archive/restore-drill.json" "a failed evaluator rerun writes no cleanup receipt"
pass "every archive must rerun its evaluator before cleanup"

# The drill must prove the archive against the fresh repository it creates, not
# against whatever repository the operator happened to be standing in.
BENCH="$TMP_ROOT/archive"
rm -f "$BENCH/archive/restore-drill.json"
DRILL_CWD="$TMP_ROOT/not-a-repo"
mkdir -p "$DRILL_CWD"
git -C "$DRILL_CWD" rev-parse --git-dir >/dev/null 2>&1 \
  && fail "the drill fixture directory must not be inside a repository"
out=$(cd "$DRILL_CWD" && run_gate "$BENCH" restore-drill) \
  || fail "the restore drill must pass from a non-repository directory: $out"
assert_present "$BENCH/archive/restore-drill.json" "the drill writes its receipt from any directory"
pass "the restore drill verifies each bundle inside the repository it restores into"

printf 'tampered\n' >> "$BENCH/archive/a-a1-fable-5-high/verdict.md"
out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "a tampered archive re-refuses cleanup"
assert_contains "$out" "no longer verifies" "the receipt does not outlive the bytes it covered"
printf 'label K7 -> candidate\n' > "$BENCH/archive/a-a1-fable-5-high/verdict.md"
pass "one changed archived byte withdraws the cleanup authority"

BENCH="$TMP_ROOT/archive-bundleless"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo2"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["groups"]["candidate_bundle_and_projection"] = ["projection.diff"]
record["files"].pop("candidate.bundle")
(sample / "candidate.bundle").unlink()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a projection with no bundle cannot be rejudged"
assert_contains "$out" "cannot be rejudged" "an archive without its bundle fails the drill"
assert_absent "$BENCH/archive/restore-drill.json" "a failed drill writes no receipt"
pass "an archive that cannot be rejudged writes no receipt and authorises no cleanup"

# --- the corrected promotion rule -------------------------------------------

write_results() {  # <bench-dir> <mode>
  local bench=$1 mode=$2
  python3 - "$bench" "$mode" <<'PY'
import json, sys
from pathlib import Path

bench, mode = Path(sys.argv[1]), sys.argv[2]
plan = json.loads((bench / "benchmark.json").read_text())
out = bench / "results"
if out.is_dir():
    for stale in out.glob("*.json"):
        stale.unlink()
out.mkdir(exist_ok=True)
winners = {"A": "Fable 5 High", "B": "Terra 5.6 High", "C": "GPT 5.6 Sol High"}

def write(track, packet, candidate, role, composite, status="scored", blocker=False, suffix=""):
    slug = f"{track}-{packet}-{candidate}{suffix}".lower().replace(" ", "-").replace(".", "-")
    (out / f"{slug}.json").write_text(json.dumps({
        "schema": "fm-bench-result.v1", "track": track, "packet": packet,
        "candidate": candidate, "role": role, "status": status,
        "blocker_class": blocker, "composite": composite,
        "deterministic": composite - 0.5}, indent=2, sort_keys=True) + "\n")

for name in sorted(plan["tracks"]):
    track = plan["tracks"][name]
    ids = [packet["id"] for packet in track["packets"]]
    for entrant in track["entrants"]:
        win = entrant["name"] == winners[name]
        for index, packet in enumerate(ids):
            score = 9.0 if win else 7.0
            blocker = False
            if win and mode == "split" and index == 2:
                score = 6.0
            if win and mode == "blocker" and index == 1:
                blocker = True
            if win and mode == "thin":
                score = 7.5
            write(name, packet, entrant["name"], "entrant", score, blocker=blocker)
        if win and mode == "void":
            write(name, ids[0], entrant["name"], "entrant", 0.0, status="void", suffix="-void")
        if win and mode == "ninth":
            write(name, ids[0], entrant["name"], "entrant", 9.0, suffix="-rerun")
    if "baseline" in track:
        for packet in track["baseline_packets"]:
            base = 9.5 if mode == "veto" else 7.5
            write(name, packet, track["baseline"]["name"], "baseline", base)
PY
}

BENCH="$TMP_ROOT/promote"
write_plan "$BENCH"
write_results "$BENCH" sweep
out=$(run_gate "$BENCH" promote-evaluate) || fail "a clean sweep must be promotable: $out"
assert_contains "$out" "ranks first on all 6 packets" "the sweep is over six distinct packets"
assert_contains "$out" "standing route eligible" "a sweep with margin is eligible"
assert_contains "$out" "subject to the captain's explicit word" "promotion still needs the captain"
assert_contains "$out" "no benchmark candidate ships directly" "the no-direct-ship rule is restated at the verdict"
pass "a six-of-six sweep with margin and no regression is the only promotable result"

refuses_promotion() {  # <label> <mode> <expected>
  local label=$1 mode=$2 expected=$3
  local bench="$TMP_ROOT/promote-$mode"
  write_plan "$bench"
  write_results "$bench" "$mode"
  local output status
  output=$(run_gate "$bench" promote-evaluate) && status=0 || status=$?
  expect_code 1 "$status" "$label must refuse promotion"
  assert_contains "$output" "$expected" "$label"
}

refuses_promotion "five of six wins" split "no standing route"
refuses_promotion "a blocker-class failure" blocker "carries a blocker-class failure"
refuses_promotion "a margin under the predeclared bar" thin "below the predeclared bar"
refuses_promotion "a baseline regression" veto "regression veto fired"
refuses_promotion "a void with no scored replacement" void "no scored replacement"
refuses_promotion "an extra sample beyond the approved six" ninth "no adaptive extension"
pass "five of six, a blocker, a thin margin, a regression, a void, and a seventh sample all refuse"
