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
CONFINE="$ROOT/bin/fm-bench-confine.sh"
IMAGE=${FM_BENCH_CONFINE_IMAGE:-debian:stable-slim}
TMP_ROOT=$(fm_test_tmproot fm-bench-gate)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

RESTORE_MECHANISM=
if command -v bwrap >/dev/null 2>&1; then
  RESTORE_MECHANISM=bwrap
else
  for runtime in docker podman; do
    if command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1 \
      && "$runtime" image inspect "$IMAGE" >/dev/null 2>&1; then
      RESTORE_MECHANISM=container
      break
    fi
  done
fi

# Every fixture starts from one corrected plan and then breaks exactly one thing,
# so a refusal is always attributable to the correction under test.
write_plan() {  # <bench-dir> [python-mutation]
  local bench=$1 mutation=${2:-}
  mkdir -p "$bench"
  python3 - "$bench/benchmark.json" "$mutation" <<'PY'
import json, sys

path, mutation = sys.argv[1], sys.argv[2]

def candidate(name, family, harness, model, effort="high", **extra):
    row = {"name": name, "family": family, "harness": harness, "model": model,
           "effort": effort, "metered_provider": False}
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
        "baseline_required": baseline is not None,
        "capture_required": False,
        "specification_required": False,
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
        "composite": {
            "weights": {"deterministic": 0.5, "panel": 0.5},
            "score_scale": {"min": 0.0, "max": 10.0},
        },
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
            specification_required=True,
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

write_freeze_inputs() {  # <bench-dir>
  local bench=$1
  python3 - "$bench" <<'PY'
import json, sys
from pathlib import Path

bench = Path(sys.argv[1])
plan = json.loads((bench / "benchmark.json").read_text())
for track in plan["tracks"].values():
    for packet in track["packets"]:
        packet_id = packet["id"]
        packet_dir = bench / "packets" / packet_id
        packet_dir.mkdir(parents=True, exist_ok=True)
        (packet_dir / "packet.md").write_text(f"packet {packet_id}\n")
        truth = bench / "ground-truth" / f"{packet_id}.md"
        truth.parent.mkdir(parents=True, exist_ok=True)
        truth.write_text(f"sealed truth {packet_id}\n")
(bench / "scoring").mkdir(parents=True, exist_ok=True)
(bench / "scoring" / "composite.py").write_text("def score(): return 1\n")
(bench / "judge-prompts").mkdir(parents=True, exist_ok=True)
(bench / "judge-prompts" / "common.md").write_text("common neutral judge prompt\n")
PY
}

write_provenance() {  # <bench-dir> <packet> <mode>
  local bench=$1 packet=$2 mode=$3
  mkdir -p "$bench/provenance"
  if [ "$mode" = cleared ]; then
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "role_absences":{"judge":"the original work had no judge"},
 "participants":[
  {"task_id":"$packet-author","role":"author","model_id":"zai/glm-5.3-flash","family":"zai","session_id":"pi-1"},
  {"task_id":"$packet-review","role":"reviewer","model_id":"zai/glm-5.3","family":"zai","session_id":"pi-2"}]}
EOF
  else
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "role_absences":{"reviewer":"the review record is unavailable","judge":"the original work had no judge"},
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

bench_evidence_digest() {  # <bench-dir>
  run_gate "$1" evidence-digest \
    | sed -n 's/^BENCH_CHECK launch\.evidence_digest ok //p' | head -n 1
}

# Mint the receipt a passing preflight would write, taking the evidence binding
# from the gate itself rather than recomputing the gate's digest in the test.
write_receipt() {  # <bench-dir> [isolation-hash-override]
  local bench=$1 isolation_override=${2:-} digest
  digest=$(bench_evidence_digest "$bench")
  [ -n "$digest" ] || fail "the gate reported no evidence digest for $bench"
  python3 - "$bench" "$digest" "$isolation_override" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench, evidence, isolation_override = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
isolation = bench / "isolation.json"
receipt = {
    "schema": "fm-bench-preflight-receipt.v1",
    "verdict": "pass",
    "plan_sha256": hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest(),
    "evidence_sha256": evidence,
    "stages": ["plan"],
}
if isolation_override:
    receipt["isolation_sha256"] = isolation_override
elif isolation.is_file():
    receipt["isolation_sha256"] = hashlib.sha256(isolation.read_bytes()).hexdigest()
(bench / "preflight.receipt").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PY
}

run_gate_env() {  # <env-argument...> -- <bench-dir> <gate> [args...]
  local -a assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    assignments+=("$1")
    shift
  done
  shift
  local bench=$1
  shift
  env "${assignments[@]}" "$GATE" --bench "$bench" --probe-timeout 30 "$@" 2>&1
}

# --- the corrected sampling, promotion, and panel rules ---------------------

BENCH="$TMP_ROOT/plan-ok"
write_plan "$BENCH"
out=$(run_gate "$BENCH" plan-check) || fail "the corrected plan must pass plan-check: $out"
assert_contains "$out" "BENCH_RESULT plan-check ok" "corrected plan passes"
assert_contains "$out" "6 distinct frozen packets, one sample each" "packets are distinct, not repeated runs"
assert_contains "$out" "a standing route needs 6/6" "the sweep rule is the promotion bar"
assert_contains "$out" "track.A.spec_seat ok specification explicitly not required" \
  "a track without a design seat reports that decision"
assert_contains "$out" "track.B.spec_seat ok specification-required design seat fully evaluated" \
  "a specification-requiring track reports its evaluated seat"
assert_contains "$out" "track.C.spec_seat ok specification explicitly not required" \
  "every track reports its spec-seat scope"
assert_contains "$out" "track.A.capture_scope ok neutral capture explicitly not required" \
  "a non-capture track reports that decision"
assert_contains "$out" "track.B.capture_scope ok neutral capture explicitly required" \
  "the capture track reports that decision"
assert_contains "$out" "plan.capture_scope ok the positively declared capture field produces exactly 30 UI records" \
  "the complete capture field is required by the plan"
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
refuses "missing composite weights" \
  'plan["promotion_rule"].pop("composite")' \
  "promotion_rule.composite must declare"
refuses "non-finite composite weights" \
  'plan["promotion_rule"]["composite"]["weights"]["panel"] = float("inf")' \
  "promotion_rule.composite must declare"
refuses "negative composite weights" \
  'plan["promotion_rule"]["composite"]["weights"] = {"deterministic": 1.1, "panel": -0.1}' \
  "promotion_rule.composite must declare"
refuses "unnormalized composite weights" \
  'plan["promotion_rule"]["composite"]["weights"] = {"deterministic": 0.6, "panel": 0.6}' \
  "promotion_rule.composite must declare"
refuses "a baseline treated as a competing peer" \
  'plan["promotion_rule"]["baseline_role"] = "competitor"' \
  "regression_veto"
refuses "a baseline mean floor looser than zero" \
  'plan["promotion_rule"]["baseline_veto"]["max_negative_mean_quality_delta"] = -0.5' \
  "must keep max_negative_mean_quality_delta at 0"
refuses "a baseline loss limit above one" \
  'plan["promotion_rule"]["baseline_veto"]["max_losses_of_three"] = 2' \
  "max_losses_of_three between 0 and 1"
refuses "an unstratified baseline subset" \
  'plan["tracks"]["A"]["baseline_packets"] = ["A1", "A2", "A3"]' \
  "preregistered stratified subset"
refuses "an undeclared baseline capability" \
  'plan["tracks"]["A"].pop("baseline_required")' \
  "track.A.baseline_scope fail baseline_required must explicitly declare true or false"
refuses "a baseline contradicting its declared capability" \
  'plan["tracks"]["A"]["baseline_required"] = False' \
  "baseline_required false conflicts with a baseline or baseline_packets"
refuses "an undeclared neutral-capture capability" \
  'plan["tracks"]["A"].pop("capture_required")' \
  "track.A.capture_scope fail capture_required must explicitly declare true or false"
refuses "a capture wave contradicting its declared capability" \
  'plan["tracks"]["A"]["wave"] = "single-complete"' \
  "wave may be declared only when capture_required is true"
refuses "an undeclared specification capability" \
  'plan["tracks"]["A"].pop("specification_required")' \
  "track.A.spec_seat fail specification_required must explicitly declare true or false"
refuses "a design seat contradicting its declared capability" \
  'plan["tracks"]["A"]["spec_author"] = {"name": "Design Author", "family": "mistral"}' \
  "specification_required false conflicts with neutral capture or design-seat fields"
refuses "a field with no complete capture track" \
  'plan["tracks"]["B"]["capture_required"] = False; plan["tracks"]["B"].pop("wave")' \
  "plan.capture_scope fail"
refuses "a capture track that opts out of its specification seat" \
  'track = plan["tracks"]["B"]; track["specification_required"] = False; track.pop("spec_author"); track.pop("spec_audit")' \
  "specification_required false conflicts with neutral capture or design-seat fields: capture_required"
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
refuses "an unaudited specification outside the capture track" \
  'track = plan["tracks"]["A"]; track["specification_required"] = True; track["spec_author"] = {"name": "Design Author", "family": "mistral"}; track["spec_audit"] = [{"packet": packet["id"], "auditor": "Independent Auditor", "auditor_family": "cohere", "pre_freeze": True, "verdict": "accepted"} for packet in track["packets"]]; track["spec_audit"][2]["pre_freeze"] = False' \
  "track.A.spec_audit_independent fail"
refuses "a specification audit with no auditor family" \
  'plan["tracks"]["B"]["spec_audit"][2]["auditor_family"] = ""' \
  "track.B.spec_audit_independent fail"
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
refuses "an entrant with no metering declaration" \
  'plan["tracks"]["A"]["entrants"][0].pop("metered_provider")' \
  "must explicitly declare a metered provider name or false"
refuses "a Cursor entrant declared unmetered" \
  'plan["tracks"]["B"]["entrants"][1]["metered_provider"] = False' \
  "uses Cursor but declares no metered provider"
refuses "an outcome-dependent implementation probe" \
  'plan["tracks"]["A"]["optional_probe"] = "A2 only"' \
  "preregistered for all samples"
pass "every refused plan names the correction it violates"

BENCH="$TMP_ROOT/spec-author-absent"
write_plan "$BENCH" 'plan["tracks"]["B"].pop("spec_author")'
out=$(run_gate "$BENCH" plan-check) && status=0 || status=$?
expect_code 1 "$status" "a specification-requiring track without an author is refused"
assert_contains "$out" "track.B.spec_seat fail track requires a specification but spec_author must name an author and family" \
  "the missing author is named accurately"
assert_not_contains "$out" "track.B.spec_author_not_judge" "an absent author is not accused of judging"
assert_not_contains "$out" "track.B.spec_author_not_entrant" "an absent author is not accused of entering"
assert_not_contains "$out" "track.B.spec_audit_independent" "author-dependent audit checks are not misreported"
pass "a missing specification author produces one accurate seat refusal"

BENCH="$TMP_ROOT/evaluator-scope-absent"
write_plan "$BENCH" 'plan["tracks"]["A"].pop("capture_required")'
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "evaluator verification refuses an undeclared capture scope"
assert_contains "$out" "evaluator.scope fail capture_required must explicitly declare true or false for tracks: A" \
  "evaluator verification owns the capture declaration too"
pass "direct evaluator verification cannot bypass a missing capture declaration"

BENCH="$TMP_ROOT/evaluator-scope-empty"
write_plan "$BENCH" 'plan["tracks"]["B"]["capture_required"] = False; plan["tracks"]["B"].pop("wave")'
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "evaluator verification refuses an explicitly empty benchmark capture field"
assert_contains "$out" "evaluator.scope fail the frozen plan must positively declare a complete 30-record UI capture field, got 0" \
  "an explicit per-track opt-out cannot remove the captain-fixed complete field"
assert_not_contains "$out" "evaluator.scope ok no track requires neutral capture" \
  "an empty field never passes through a silent scope exemption"
pass "direct evaluator verification requires the complete capture field"

# --- positive provenance before a historical replay -------------------------

BENCH="$TMP_ROOT/prov"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 absent
out=$(run_gate "$BENCH" provenance-check) && status=0 || status=$?
expect_code 3 "$status" "an unclearable historical packet is a captain call"
assert_contains "$out" "BENCH_CHECK provenance.A1 ok" "a positively identified packet clears"
assert_contains "$out" "1 roles positively absent" "a reasoned absent role completes provenance explicitly"
assert_contains "$out" "missing model_id/family/session_id" "an absent record never clears a replay"
assert_contains "$out" "never a substitution" "a replacement packet stays a captain call"
pass "provenance clears only on positive identification, and failing both is a captain call"

BENCH="$TMP_ROOT/prov-missing-role"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
python3 - "$BENCH/provenance/A1.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
record = json.loads(path.read_text())
record["participants"] = [participant for participant in record["participants"] if participant["role"] != "reviewer"]
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" provenance-check) && status=0 || status=$?
expect_code 3 "$status" "an undeclared original reviewer keeps a historical track stopped"
assert_contains "$out" "identify or positively declare absent: reviewer" \
  "every original participant role must be covered"
pass "historical provenance refuses a silently omitted participant role"

BENCH="$TMP_ROOT/prov-empty-role-reason"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
python3 - "$BENCH/provenance/A1.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
record = json.loads(path.read_text())
record["role_absences"]["judge"] = "unknown"
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" provenance-check) && status=0 || status=$?
expect_code 3 "$status" "an empty-value role declaration cannot clear provenance"
assert_contains "$out" "role absence declarations are malformed" \
  "a positive absence requires a real reason"
pass "historical provenance rejects an absent role with no reason"

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
        "role_absences": {"reviewer": "the original work had no reviewer",
                          "judge": "the original work had no judge"},
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

BENCH="$TMP_ROOT/cost-incomplete"
write_plan "$BENCH" 'plan["cost_model"]["job_classes"].pop("planning_run")'
out=$(run_gate "$BENCH" manifest-build) && status=0 || status=$?
expect_code 1 "$status" "an unpriced referenced run class is refused"
assert_contains "$out" "referenced job classes are absent: planning_run" "missing run prices cannot become zero cost"
pass "every referenced run and auxiliary cost class must be complete"

BENCH="$TMP_ROOT/cost-nonfinite"
write_plan "$BENCH" 'plan["cost_model"]["job_classes"]["judge_call"]["high"] = float("inf")'
out=$(run_gate "$BENCH" manifest-build) && status=0 || status=$?
expect_code 1 "$status" "a non-finite unit price is refused"
assert_contains "$out" "lack ordered low/base/high unit costs: judge_call" "non-finite arithmetic cannot enter the manifest"
pass "cost bounds and the approved class must be finite"

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
  mkdir -p "$e/determinism" "$e/mutations" "$e/captures" "$bench/scoring"
  cat > "$bench/scoring/evaluator.sh" <<'EOF'
#!/bin/sh
[ "${1:-}" = --evaluate ] && [ -f "${2:-}" ] || exit 2
sed 's/"schema":"fm-bench-evaluator-input.v1","fixture":/"schema":"fm-bench-evaluator-output.v1","result":/' "$2"
EOF
  chmod +x "$bench/scoring/evaluator.sh"
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
before = {name: 10.0 for name in names}
after = dict(before); after[dim] = 4.0
json.dump({"dimension": dim, "movement_threshold": 1.0, "dimension_deltas": deltas,
           "scores_before": before, "scores_after": after},
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
        record = {
            "entrant": entrant, "packet": f"B{index}",
            "original_sha": hashlib.sha1(seed + b"o").hexdigest(), "original_tree": tree,
            "neutral_sha": hashlib.sha1(seed + b"n").hexdigest(), "neutral_tree": tree,
            "base_tree": hashlib.sha1(b"base").hexdigest(),
            "patch_hash": hashlib.sha256(seed).hexdigest()}
        payload = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
        record["result_hash"] = hashlib.sha256(payload).hexdigest()
        (out / f"{slug}-b{index}.json").write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        written += 1
PY
  python3 - "$bench" "$e/execution.json" "$bench/scoring/evaluator.sh" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench, path, program = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
evaluator = bench / "evaluator"
records = {}
for record in [
    evaluator / "determinism" / "run-1.json",
    evaluator / "determinism" / "run-2.json",
    *sorted((evaluator / "mutations").glob("*.json")),
    *sorted((evaluator / "captures").glob("*.json")),
]:
    relative = record.relative_to(evaluator)
    result = json.loads(record.read_text())
    input_path = bench / "ground-truth" / "evaluator-inputs" / relative
    output_path = bench / "ground-truth" / "evaluator-outputs" / relative
    input_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    input_path.write_text(json.dumps({
        "schema": "fm-bench-evaluator-input.v1",
        "fixture": result,
    }, separators=(",", ":")) + "\n")
    output_path.write_text(json.dumps({
        "schema": "fm-bench-evaluator-output.v1",
        "result": result,
    }, separators=(",", ":")) + "\n")
    records[relative.as_posix()] = {
        "input": {
            "path": input_path.relative_to(bench).as_posix(),
            "sha256": hashlib.sha256(input_path.read_bytes()).hexdigest(),
        },
        "expected_output": {
            "path": output_path.relative_to(bench).as_posix(),
            "sha256": hashlib.sha256(output_path.read_bytes()).hexdigest(),
        },
    }
json.dump({
    "program": "scoring/evaluator.sh",
    "sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
    "records": records,
}, path.open("w"), indent=2, sort_keys=True)
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
assert_contains "$out" "no declared tolerance can stand in for reproducibility" \
  "an unexplained rerun difference is refused"
python3 - "$BENCH/evaluator/determinism/bound.json" <<'PY'
import json, sys
json.dump({"max_image_delta": 1000000, "observed_image_delta": 0,
           "structural_fields_identical": True}, open(sys.argv[1], "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" evaluator-verify) && status=0 || status=$?
expect_code 1 "$status" "a self-authored tolerance cannot clear differing dry-runs"
assert_contains "$out" "no declared tolerance can stand in for reproducibility" \
  "the determinism gate recomputes rather than reading a declared bound"
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
write_freeze_inputs "$BENCH"
out=$(run_gate "$BENCH" freeze) || fail "freeze must succeed before labels exist: $out"
out=$(run_gate "$BENCH" freeze-check) || fail "a fresh freeze must verify: $out"
printf 'edited truth\n' > "$BENCH/ground-truth/A1.md"
out=$(run_gate "$BENCH" freeze-check) && status=0 || status=$?
expect_code 1 "$status" "ground truth edited after the freeze is refused"
assert_contains "$out" "changed after the freeze" "the freeze binds the sealed inputs"
pass "the freeze binds packets, ground truth, scoring, prompts, tuples, seed, and failure policy"

BENCH="$TMP_ROOT/freeze-missing-input"
write_plan "$BENCH"
write_freeze_inputs "$BENCH"
rm "$BENCH/ground-truth/C6.md"
out=$(run_gate "$BENCH" freeze) && status=0 || status=$?
expect_code 1 "$status" "a freeze missing one planned private input is refused"
assert_contains "$out" "ground-truth is missing planned packet inputs: C6" \
  "the missing plan-derived ground truth is named"
assert_absent "$BENCH/freeze.json" "an incomplete private input set writes no freeze"
pass "every planned packet and ground-truth input must exist before freezing"

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
    "launch_wrapper": [confine, "--mechanism", "none", "--allow", "{root}", "--"],
    "entrants": [{"id": "bench-b1-k7", "root": str(entrant),
                  "private_object_store": str(entrant / "objects"),
                  "private_tmp": str(entrant / "tmp"),
                  "private_home": str(entrant / "home with space"),
                  "private_session": str(entrant / "session"),
                  "provider_network": "provider-egress-k7",
                  "provider_proxy": "http://provider-proxy-k7:8080",
                  "provider_proxy_container": "provider-proxy-k7"}],
}, indent=2, sort_keys=True) + "\n")
PY
write_receipt "$BENCH"
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
write_receipt "$BENCH" "$(printf '0%.0s' $(seq 1 64))"
out=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch bench-b1-k7 "$2" "printf unsafe"
' _ "$ROOT" "$ENTRY_ROOT" 2>&1) && status=0 || status=$?
expect_code 1 "$status" "a launch may not use an isolation layout changed after preflight"
assert_contains "$out" "does not cover the current isolation layout" "the preflight binds the isolation layout"
python3 - "$BENCH/isolation.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["launch_wrapper"][0] = "/missing/benchmark-wrapper"
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
PY
write_receipt "$BENCH"
out=$(FM_BENCH_ROOT="$BENCH" bash -c '
  . "$1/bin/fm-bench-launch-lib.sh"
  fm_bench_wrap_entrant_launch bench-b1-k7 "$2" "printf unsafe"
' _ "$ROOT" "$ENTRY_ROOT" 2>&1) && status=0 || status=$?
expect_code 1 "$status" "a benchmark launch with no verified wrapper is refused"
assert_contains "$out" "cannot use its preflight-proven confinement" "the launch refuses rather than falling back unconfined"
pass "benchmark launches bind the preflight-proven confinement while ordinary launches stay unchanged"

FAKE_RUNTIME_BIN="$TMP_ROOT/provider-runtime-bin"
mkdir -p "$FAKE_RUNTIME_BIN"
cat > "$FAKE_RUNTIME_BIN/docker" <<'EOF'
#!/bin/sh
case "$1 $2" in
  "info ") exit 0 ;;
  "network inspect")
    if [ -n "${BENCH_TEST_NETWORK_TOPOLOGY:-}" ]; then
      printf '%s\n' "$BENCH_TEST_NETWORK_TOPOLOGY"
    else
      suffix=${3##*-}
      printf 'true provider-proxy-%s \n' "$suffix"
    fi
    exit 0
    ;;
  "run --rm") printf '%s\n' "$*"; sleep 1; exit 0 ;;
  *) exit 9 ;;
esac
EOF
chmod +x "$FAKE_RUNTIME_BIN/docker"
out=$(PATH="$FAKE_RUNTIME_BIN:$PATH" BENCH_TEST_NETWORK_TOPOLOGY="false provider-proxy " \
  "$ROOT/bin/fm-bench-confine.sh" --purpose entrant --mechanism container \
  --image runtime@sha256:test --provider-network provider-only \
  --provider-proxy http://provider-proxy:8080 --provider-proxy-container provider-proxy \
  --allow "$ENTRY_ROOT" -- /bin/true 2>&1) && status=0 || status=$?
expect_code 2 "$status" "an internet-routed provider network is refused"
assert_contains "$out" "must be internal and contain only provider-proxy" \
  "the launch wrapper verifies the provider-egress topology"
pass "entrant egress refuses a network that exposes more than the provider proxy"

PATH="$FAKE_RUNTIME_BIN:$PATH" "$CONFINE" --purpose entrant --mechanism container \
  --image runtime@sha256:test --provider-network provider-egress-k7 \
  --provider-proxy http://provider-proxy-k7:8080 --provider-proxy-container provider-proxy-k7 \
  --allow "$ENTRY_ROOT" -- /bin/true >"$TMP_ROOT/k7-launch" 2>&1 &
k7_pid=$!
PATH="$FAKE_RUNTIME_BIN:$PATH" "$CONFINE" --purpose entrant --mechanism container \
  --image runtime@sha256:test --provider-network provider-egress-r2 \
  --provider-proxy http://provider-proxy-r2:8080 --provider-proxy-container provider-proxy-r2 \
  --allow "$ENTRY_ROOT" -- /bin/true >"$TMP_ROOT/r2-launch" 2>&1 &
r2_pid=$!
wait "$k7_pid" || fail "the first dedicated entrant network must launch"
wait "$r2_pid" || fail "the second dedicated entrant network must launch concurrently"
assert_contains "$(cat "$TMP_ROOT/k7-launch")" "--network provider-egress-k7" \
  "the first entrant stays on its own internal network"
assert_contains "$(cat "$TMP_ROOT/r2-launch")" "--network provider-egress-r2" \
  "the second entrant stays on a different internal network"
pass "two entrants can launch concurrently without sharing a network or proxy boundary"

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
write_receipt "$BENCH"
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
write_receipt "$BENCH"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=0" "the clearance stands while it matches the plan"
out=$(run_gate "$BENCH" preflight) && status=0 || status=$?
expect_code 1 "$status" "a preflight without isolation evidence must refuse"
assert_contains "$out" "the prior clearance is revoked" "the refusal reports the revocation"
assert_absent "$BENCH/preflight.receipt" "a refusing preflight removes the receipt it wrote"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "the launch guard refuses once the clearance is revoked"
pass "evidence degrading outside the plan revokes the clearance rather than leaving it standing"

# The receipt binds every artifact the preflight validated, not just the plan
# and the isolation layout, so evidence edited without a rerun withdraws it.
BENCH="$TMP_ROOT/evidence-binding"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
write_evaluator "$BENCH"
run_gate "$BENCH" manifest-build >/dev/null
write_freeze_inputs "$BENCH"
run_gate "$BENCH" freeze >/dev/null
write_receipt "$BENCH"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=0" "a receipt covering the current evidence permits the launch"
rm -f "$BENCH"/evaluator/captures/*.json
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "capture records deleted after the pass withdraw the clearance"
assert_contains "$out" "preflight evidence no longer holds" "the refusal names the stale evidence binding"
assert_contains "$out" "launch evidence changed after the preflight that cleared it" \
  "the gate that owns the digest reports the mismatch"
write_receipt "$BENCH"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=0" "a receipt reminted over the current evidence clears again"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1]) / "allowance.json"
record = json.loads(path.read_text()) if path.is_file() else {}
record["measured_available_runs"] = 1
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "an allowance lowered after the pass withdraws the clearance"
pass "the launch receipt binds every artifact the preflight validated"

BENCH="$TMP_ROOT/evidence-symlink"
write_plan "$BENCH"
write_receipt "$BENCH"
mv "$BENCH/benchmark.json" "$BENCH/benchmark-real.json"
ln -s "$BENCH/benchmark-real.json" "$BENCH/benchmark.json"
out=$(guard "bench-b1-k7" "$BENCH")
assert_contains "$out" "rc=1" "a launch artifact replaced by a symlink is refused"
assert_contains "$out" "launch evidence is symlinked or a special file: benchmark.json" \
  "the refusal names the substituted artifact"
pass "substituted launch evidence is refused by type, not only by bytes"

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
  printf 'objects/\ntmp/\nhome/\nsession/\n' > "$ISO/$entrant/.gitignore"
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
    "launch_wrapper": [confine, "--purpose", "entrant", "--mechanism", "container",
                       "--image", "firstmate-benchmark-runtime@sha256:test",
                       "--provider-network", "{provider_network}",
                       "--provider-proxy", "{provider_proxy}",
                       "--provider-proxy-container", "{provider_proxy_container}",
                       "--allow", "{root}", "--"],
    "leak_marker": "FM_BENCH_",
    "protected_paths": [f"{iso}/sealed"],
    "entrants": [
        {"id": f"bench-b1-{label}", "root": f"{iso}/{name}",
         "private_object_store": f"{iso}/{name}/objects",
         "private_tmp": f"{iso}/{name}/tmp",
         "private_home": f"{iso}/{name}/home",
         "private_session": f"{iso}/{name}/session",
         "provider_network": f"provider-egress-{label}",
         "provider_proxy": f"http://provider-proxy-{label}:8080",
         "provider_proxy_container": f"provider-proxy-{label}"}
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

BENCH="$TMP_ROOT/iso-shared-provider-boundary"
write_plan "$BENCH"
write_isolation "$BENCH" none
python3 - "$BENCH/isolation.json" <<'PY'
import json, sys
path = sys.argv[1]
record = json.load(open(path))
record["entrants"][1]["provider_network"] = record["entrants"][0]["provider_network"]
record["entrants"][1]["provider_proxy_container"] = record["entrants"][0]["provider_proxy_container"]
json.dump(record, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "two entrants may not share one provider-egress boundary"
assert_contains "$out" "isolation.provider_boundaries fail" \
  "sibling entrants cannot reach each other through a shared internal network"
pass "each concurrent entrant requires its own provider network and proxy"

if [ -n "$RESTORE_MECHANISM" ]; then
  BENCH="$TMP_ROOT/evaluator-execution"
  write_plan "$BENCH"
  write_evaluator "$BENCH"
  write_freeze_inputs "$BENCH"
  run_gate "$BENCH" freeze >/dev/null
  write_isolation "$BENCH" "$RESTORE_MECHANISM"
  out=$(run_gate "$BENCH" evaluator-execute-verify) \
    || fail "the content-addressed evaluator must reproduce its records: $out"
  assert_contains "$out" "generated all 39 golden, mutation, and capture records" \
    "the evaluator is executed rather than inferred from record presence"
  python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
path = bench / "evaluator" / "mutations" / "fidelity.json"
record = json.loads(path.read_text())
record["dimension_deltas"]["fidelity"] = -2.0
path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
input_path = bench / "ground-truth" / "evaluator-inputs" / "mutations" / "fidelity.json"
input_path.write_text(json.dumps({
    "schema": "fm-bench-evaluator-input.v1",
    "fixture": record,
}, separators=(",", ":")) + "\n")
output_path = bench / "ground-truth" / "evaluator-outputs" / "mutations" / "fidelity.json"
output_path.write_text(json.dumps({
    "schema": "fm-bench-evaluator-output.v1",
    "result": record,
}, separators=(",", ":")) + "\n")
contract_path = bench / "evaluator" / "execution.json"
contract = json.loads(contract_path.read_text())
execution = contract["records"]["mutations/fidelity.json"]
execution["input"]["sha256"] = hashlib.sha256(input_path.read_bytes()).hexdigest()
execution["expected_output"]["sha256"] = hashlib.sha256(output_path.read_bytes()).hexdigest()
contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
PY
  run_gate "$BENCH" freeze >/dev/null
  out=$(run_gate "$BENCH" evaluator-execute-verify) && status=0 || status=$?
  expect_code 1 "$status" "self-reported mutation deltas cannot replace executed score movement"
  assert_contains "$out" "declared deltas differ from executed score vectors" \
    "the gate derives calibration deltas from evaluator execution"
  write_evaluator "$BENCH"
  python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
program = bench / "scoring" / "evaluator.sh"
program.write_text("#!/bin/sh\nexec cat \"$2\"\n")
program.chmod(0o755)
contract = bench / "evaluator" / "execution.json"
record = json.loads(contract.read_text())
record["sha256"] = hashlib.sha256(program.read_bytes()).hexdigest()
contract.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
  run_gate "$BENCH" freeze >/dev/null
  out=$(run_gate "$BENCH" evaluator-execute-verify) && status=0 || status=$?
  expect_code 1 "$status" "a content-addressed cat evaluator that echoes frozen input is refused"
  assert_contains "$out" "did not derive determinism/run-1.json from its frozen input" \
    "input and expected output schemas stay distinct even when their payloads match"
  python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
frozen = bench / "ground-truth"
output_path = frozen / "evaluator-outputs" / "determinism" / "run-1.json"
input_path = frozen / "evaluator-inputs" / "determinism" / "run-1.json"
input_path.write_bytes(output_path.read_bytes())
contract_path = bench / "evaluator" / "execution.json"
contract = json.loads(contract_path.read_text())
contract["records"]["determinism/run-1.json"]["input"]["sha256"] = hashlib.sha256(
    input_path.read_bytes()
).hexdigest()
contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
PY
  run_gate "$BENCH" freeze >/dev/null
  out=$(run_gate "$BENCH" evaluator-execute-verify) && status=0 || status=$?
  expect_code 1 "$status" "a frozen input chosen to equal its expected output is refused"
  assert_contains "$out" "determinism/run-1.json input and expected output are not structurally distinct" \
    "no choice of fixture bytes lets an echoing evaluator reproduce its expected output"
  pass "preflight evaluator evidence is generated by the frozen executable"

  # A lookup table keyed on the frozen input path answers every record without
  # measuring anything, so the gate hands the evaluator an opaque path instead.
  BENCH="$TMP_ROOT/evaluator-path-lookup"
  write_plan "$BENCH"
  write_evaluator "$BENCH"
  write_freeze_inputs "$BENCH"
  write_isolation "$BENCH" "$RESTORE_MECHANISM"
  python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
program = bench / "scoring" / "evaluator.sh"
outputs = bench / "ground-truth" / "evaluator-outputs"
cases = []
for output in sorted(outputs.rglob("*.json")):
    relative = output.relative_to(outputs).as_posix()
    cases.append("  */%s) cat %s;;" % (relative, json.dumps(str(output))))
program.write_text("#!/bin/sh\ncase \"$2\" in\n" + "\n".join(cases) + "\n  *) exit 3;;\nesac\n")
program.chmod(0o755)
contract_path = bench / "evaluator" / "execution.json"
contract = json.loads(contract_path.read_text())
contract["sha256"] = hashlib.sha256(program.read_bytes()).hexdigest()
contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
PY
  run_gate "$BENCH" freeze >/dev/null
  out=$(run_gate "$BENCH" evaluator-execute-verify) && status=0 || status=$?
  expect_code 1 "$status" "an evaluator that answers from its input path is refused"
  assert_contains "$out" "evaluator confinement or execution for determinism/run-1.json exited 3" \
    "the opaque input path matches no entry in a path-keyed answer table"
  pass "the frozen evaluator never sees the path of the record it must derive"

  # This evaluator derives every record correctly but normalises away the one
  # value the gate edits, so it reproduces its records without reading them.
  BENCH="$TMP_ROOT/evaluator-input-blind"
  write_plan "$BENCH"
  write_evaluator "$BENCH"
  write_freeze_inputs "$BENCH"
  write_isolation "$BENCH" "$RESTORE_MECHANISM"
  python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
program = bench / "scoring" / "evaluator.sh"
golden = json.loads((bench / "evaluator" / "determinism" / "run-1.json").read_text())
program.write_text(
    "#!/bin/sh\n"
    "[ \"${1:-}\" = --evaluate ] && [ -f \"${2:-}\" ] || exit 2\n"
    "sed -e 's/\"golden_head\":\"[^\"]*\"/\"golden_head\":\"%s\"/' \\\n"
    "    -e 's/\"schema\":\"fm-bench-evaluator-input.v1\",\"fixture\":/"
    "\"schema\":\"fm-bench-evaluator-output.v1\",\"result\":/' \"$2\"\n"
    % golden["golden_head"]
)
program.chmod(0o755)
contract_path = bench / "evaluator" / "execution.json"
contract = json.loads(contract_path.read_text())
contract["sha256"] = hashlib.sha256(program.read_bytes()).hexdigest()
contract_path.write_text(json.dumps(contract, indent=2, sort_keys=True) + "\n")
PY
  run_gate "$BENCH" freeze >/dev/null
  out=$(run_gate "$BENCH" evaluator-execute-verify) && status=0 || status=$?
  expect_code 1 "$status" "an evaluator blind to the perturbed value is refused"
  assert_contains "$out" "the frozen evaluator ignored its input" \
    "a gate-owned edit of the golden input must move the evaluator output"
  pass "preflight proves the frozen evaluator reads the input it is handed"
fi

# The gate resolves its container runtime through the wrapper, so the wrapper
# must inherit the names that resolution depends on. This stub runtime is only
# reachable through a non-default DOCKER_HOST, exactly as colima, a remote
# context, or rootless podman would be.
ENDPOINT_BIN="$TMP_ROOT/endpoint-runtime-bin"
mkdir -p "$ENDPOINT_BIN"
cat > "$ENDPOINT_BIN/docker" <<'EOF'
#!/bin/sh
case "$1" in
  info)
    [ "${DOCKER_HOST:-}" = "tcp://benchmark-endpoint:2375" ] || {
      echo "error: cannot connect to the Docker daemon" >&2
      exit 1
    }
    exit 0
    ;;
  run) ;;
  *) exit 9 ;;
esac
shift
while [ "$#" -gt 0 ]; do
  if [ "$1" = --workdir ]; then
    shift 2
    break
  fi
  shift
done
shift
exec "$@"
EOF
chmod +x "$ENDPOINT_BIN/docker"
cat > "$ENDPOINT_BIN/podman" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$ENDPOINT_BIN/podman"

BENCH="$TMP_ROOT/evaluator-endpoint"
write_plan "$BENCH"
write_evaluator "$BENCH"
write_freeze_inputs "$BENCH"
run_gate "$BENCH" freeze >/dev/null
write_isolation "$BENCH" container
out=$(run_gate_env "PATH=$ENDPOINT_BIN:$PATH" \
  "DOCKER_HOST=tcp://benchmark-endpoint:2375" \
  -- "$BENCH" evaluator-execute-verify) \
  || fail "the evaluator gate must reach a runtime on a non-default endpoint: $out"
assert_contains "$out" "generated all 39 golden, mutation, and capture records" \
  "the confinement wrapper inherits the endpoint the operator resolved its runtime through"
out=$(run_gate_env -u DOCKER_HOST "PATH=$ENDPOINT_BIN:$PATH" \
  -- "$BENCH" evaluator-execute-verify) && status=0 || status=$?
expect_code 1 "$status" "an unreachable runtime endpoint must refuse rather than pass"
assert_contains "$out" "no usable container runtime" \
  "the refusal names the wrapper failure instead of a stdout parse error"
pass "preflight evaluator execution resolves its runtime through the operator's endpoint"

BENCH="$TMP_ROOT/evaluator-wrapper-failure"
write_plan "$BENCH"
write_evaluator "$BENCH"
write_freeze_inputs "$BENCH"
run_gate "$BENCH" freeze >/dev/null
write_isolation "$BENCH" container
BROKEN_RUNTIME_BIN="$TMP_ROOT/broken-runtime-bin"
mkdir -p "$BROKEN_RUNTIME_BIN"
for runtime in docker podman; do
  cat > "$BROKEN_RUNTIME_BIN/$runtime" <<'EOF'
#!/bin/sh
printf 'error: benchmark stub runtime is unavailable\n' >&2
exit 1
EOF
  chmod +x "$BROKEN_RUNTIME_BIN/$runtime"
done
out=$(run_gate_env "PATH=$BROKEN_RUNTIME_BIN:$PATH" \
  -- "$BENCH" evaluator-execute-verify) && status=0 || status=$?
expect_code 1 "$status" "a confinement wrapper that cannot start is refused"
assert_contains "$out" "evaluator confinement or execution for determinism/run-1.json exited 2" \
  "the wrapper exit code is reported before its stdout is parsed"
assert_contains "$out" "no usable container runtime" \
  "the wrapper stderr explains the refusal"
pass "a failing evaluator confinement is diagnosed by its own exit code and stderr"

BENCH="$TMP_ROOT/iso-conditional-wrapper"
write_plan "$BENCH"
write_isolation "$BENCH" none
CONDITIONAL_WRAPPER="$TMP_ROOT/conditional-wrapper.sh"
cat > "$CONDITIONAL_WRAPPER" <<'EOF'
#!/usr/bin/env bash
printf 'PROBE DENIED conditional fixture\n'
EOF
chmod +x "$CONDITIONAL_WRAPPER"
python3 - "$BENCH/isolation.json" "$CONDITIONAL_WRAPPER" <<'PY'
import json, sys
path, wrapper = sys.argv[1:]
record = json.load(open(path))
record["exec_wrapper"] = [wrapper]
json.dump(record, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "a probe-specific wrapper cannot clear entrant confinement"
assert_contains "$out" "isolation.exec_wrapper fail" "the shared isolation boundary rejects the wrapper"
assert_contains "$out" "must use the executable bin/fm-bench-confine.sh" \
  "only the launch-capable trusted wrapper may supply isolation evidence"
pass "probe-only confinement cannot substitute for the entrant launch wrapper"

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

BENCH="$TMP_ROOT/iso-private-tree"
write_plan "$BENCH"
write_isolation "$BENCH" none
DENY_WRAPPER="$TMP_ROOT/deny-all-probes.sh"
cat > "$DENY_WRAPPER" <<'EOF'
#!/usr/bin/env bash
printf 'PROBE DENIED fixture confinement\n'
EOF
chmod +x "$DENY_WRAPPER"
python3 - "$BENCH/isolation.json" "$DENY_WRAPPER" <<'PY'
import json, sys
path, wrapper = sys.argv[1:]
d = json.load(open(path))
d["exec_wrapper"] = [wrapper]
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
git -C "$ISO/e1" add -f tmp/canary.txt
git -C "$ISO/e1" -c user.name=t -c user.email=t@x commit -qm private-tree-fixture
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "private storage committed into a candidate tree is refused"
assert_contains "$out" "isolation.bench-b1-k7.private_tree_exclusion fail" \
  "the gate names private material present in the candidate index"
assert_contains "$out" "private_tmp" "the tree-exclusion refusal names the offending private path"
git -C "$ISO/e1" rm --cached -q tmp/canary.txt
git -C "$ISO/e1" -c user.name=t -c user.email=t@x commit -qm remove-private-tree-fixture
pass "in-root private storage must be ignored and absent from the candidate tree"

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
python3 - "$BENCH/isolation.json" "$TMP_ROOT/env-only.sh" "$ISO" "$ROOT/bin/fm-bench-confine.sh" <<'PY'
import json, os, stat, sys
path, wrapper, iso, confine = sys.argv[1:5]
with open(wrapper, "w") as handle:
    handle.write('#!/usr/bin/env bash\nexec env -i PATH="$PATH" HOME="$HOME" "$@"\n')
os.chmod(wrapper, os.stat(wrapper).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
json.dump({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [wrapper],
    "launch_wrapper": [confine, "--purpose", "entrant", "--mechanism", "container",
                       "--image", "firstmate-benchmark-runtime@sha256:test",
                       "--provider-network", "{provider_network}",
                       "--provider-proxy", "{provider_proxy}",
                       "--provider-proxy-container", "{provider_proxy_container}",
                       "--allow", "{root}", "--"],
    "leak_marker": "FM_BENCH_",
    "protected_paths": [f"{iso}/sealed"],
    "entrants": [
        {"id": f"bench-b1-{label}", "root": f"{iso}/{name}",
         "private_object_store": f"{iso}/{name}/objects",
         "private_tmp": f"{iso}/{name}/tmp",
         "private_home": f"{iso}/{name}/home",
         "private_session": f"{iso}/{name}/session",
         "provider_network": f"provider-egress-{label}",
         "provider_proxy": f"http://provider-proxy-{label}:8080",
         "provider_proxy_container": f"provider-proxy-{label}"}
        for label, name in (("k7", "e1"), ("r2", "e2"))],
}, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "partial confinement earns no partial credit"
assert_contains "$out" "isolation.bench-b1-k7.environment_leakage ok" "the environment probe really flips to denied"
assert_contains "$out" "isolation.bench-b1-k7.sibling_file_read fail" "shared filesystem access still refuses the gate"
pass "per-probe verdicts are real, and partial confinement still refuses the launch"

BENCH="$TMP_ROOT/iso-missing-tool"
write_plan "$BENCH"
write_isolation "$BENCH" none
NO_FIND_BIN="$TMP_ROOT/no-find-bin"
MISSING_TOOL_WRAPPER="$TMP_ROOT/missing-tool-wrapper.sh"
mkdir -p "$NO_FIND_BIN"
ln -s "$(command -v bash)" "$NO_FIND_BIN/bash"
cat > "$MISSING_TOOL_WRAPPER" <<EOF
#!/usr/bin/env bash
if [ "\${2:-}" = sibling_file_read ]; then
  PATH='$NO_FIND_BIN' "\$@"
else
  printf 'PROBE DENIED fixture confinement\\n'
fi
EOF
chmod +x "$MISSING_TOOL_WRAPPER"
python3 - "$BENCH/isolation.json" "$MISSING_TOOL_WRAPPER" <<'PY'
import json, sys
path, wrapper = sys.argv[1:]
d = json.load(open(path))
d["exec_wrapper"] = [wrapper]
json.dump(d, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" isolation-verify) && status=0 || status=$?
expect_code 1 "$status" "a missing probe utility cannot count as an isolation denial"
assert_contains "$out" "required tool is unavailable: find" "the absent required utility is reported"
assert_contains "$out" "inconclusive against" "the gate refuses an unmeasurable confined probe"
pass "a confinement missing a required probe utility is inconclusive, never denied"

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

write_restore_confinement() {  # <bench-dir> [mechanism]
  local bench=$1 mechanism=${2:-$RESTORE_MECHANISM}
  python3 - "$bench" "$CONFINE" "$mechanism" <<'PY'
import hashlib, json, sys
from pathlib import Path

bench, confine, mechanism = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
isolation = bench / "isolation.json"
isolation.write_text(json.dumps({
    "schema": "fm-bench-isolation.v1",
    "exec_wrapper": [confine, "--mechanism", mechanism, "--allow", "{root}", "--"],
}, indent=2, sort_keys=True) + "\n")
(bench / "preflight.receipt").write_text(json.dumps({
    "schema": "fm-bench-preflight-receipt.v1",
    "verdict": "pass",
    "plan_sha256": hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest(),
    "isolation_sha256": hashlib.sha256(isolation.read_bytes()).hexdigest(),
    "stages": ["isolation"],
}, indent=2, sort_keys=True) + "\n")
PY
}

write_archive() {  # <bench-dir> <src-repo> [png-mode]
  local bench=$1 src=$2 png_mode=${3:-normal}
  python3 - "$bench" "$src" "$ROOT" "$png_mode" <<'PY'
import hashlib, json, shlex, shutil, struct, subprocess, sys, zlib
from pathlib import Path

bench, src, repo_root, png_mode = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
plan = json.loads((bench / "benchmark.json").read_text())
operator_secret = bench / "operator-secret.txt"
operator_secret.write_text("not evaluator input\n")
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
        work.extend((name, "entrant", entrant["name"], pid) for pid in ids)
    if "baseline" in track:
        work.extend((name, "baseline", track["baseline"]["name"], pid) for pid in track["baseline_packets"])

root = bench / "archive"
shutil.rmtree(root, ignore_errors=True)
for track_name, role, candidate, packet in work:
    slug = f"{track_name}-{packet}-{candidate}".lower().replace(" ", "-").replace(".", "-")
    (src / ".ignored-by-evaluator").write_text("not scored\n")
    (src / "genuine").write_text(json.dumps({"value": slug}, indent=2, sort_keys=True) + "\n")
    (src / "work-bool.json").write_text('{"value":true}\n')
    (src / "work-empty.json").write_text('{"value":""}\n')
    (src / "work.json").write_text(json.dumps({"value": slug}, indent=2, sort_keys=True) + "\n")
    (src / "work-number.json").write_text('{"n":3}\n')
    (src / "work.ts").write_text(f'export default "{slug}";\n')
    (src / "work.css").write_text(f'.sample::after {{ content: "{slug}"; }}\n')
    (src / "work.html").write_text(f'<main data-sample="{slug}">candidate</main>\n')
    link = src / "work-link.json"
    link.unlink(missing_ok=True)
    link.symlink_to("work.json")
    empty_link = src / "work-empty-link.json"
    empty_link.unlink(missing_ok=True)
    empty_link.symlink_to("work-empty.json")
    width = height = 20_000 if png_mode == "oversized" else 1
    pixels = b"\x00" if png_mode == "oversized" else b"\x00\x20\x40\x60"
    compressed = zlib.compress(pixels)
    split = max(1, len(compressed) // 2)
    png_chunks = []
    for kind, payload in (
        (b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)),
        (b"IDAT", compressed[:split]),
        (b"IDAT", compressed[split:]),
        (b"IEND", b""),
    ):
        png_chunks.append(
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )
    (src / "work.png").write_bytes(b"\x89PNG\r\n\x1a\n" + b"".join(png_chunks))
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
    capture_hash = hashlib.sha256((slug + "-capture").encode()).hexdigest()
    put("capture.json", json.dumps({"deterministic": 8.0, "tree": tree,
                                     "capture_hash": capture_hash}, sort_keys=True) + "\n")
    scoring = f"""#!/bin/sh
if [ -r {shlex.quote(str(operator_secret))} ] || [ -r {shlex.quote(str(repo_root / 'bin' / 'fm-bench-gate.py'))} ]; then
  printf 'unconfined host access\\n'
  exit 0
fi
value=$(sed -n 's/^[[:space:]]*"value":[[:space:]]*"\\([^"]*\\)".*$/\\1/p' "$1/work.json")
if [ -z "$value" ]; then
  printf 'invalid structured input\n' >&2
  exit 9
fi
actual=$(cat "$1/work.json")
expected_document=$(printf '{{\n  "value": "%s"\n}}' "$value")
if [ "$actual" != "$expected_document" ]; then
  printf 'scored input changed outside its declared value\n' >&2
  exit 10
fi
printf '%s\n' "$value"
"""
    put("scoring.py", scoring)
    (out / "scoring.py").chmod(0o755)
    panel = [judge["name"] for judge in track["judges"]]
    put("judging.json", json.dumps({"panel": panel, "scores": [8.0 for _ in panel]}, sort_keys=True) + "\n")
    put("timing.json", json.dumps({"intervals": {
        "dispatch_accepted_to_first_valid_final_commit": 1200,
        "first_assistant_event_to_first_valid_final_commit": 1100},
        "failure": {"status": "scored", "blocker_class": False, "class": "none"}}, sort_keys=True) + "\n")
    put("verdict.md", "label K7 -> candidate\n")
    binding = {"original_sha": sha, "original_tree": tree, "neutral_sha": sha,
               "neutral_tree": tree, "base_tree": base_tree,
               "patch_hash": hashlib.sha256(slug.encode()).hexdigest()}
    put("tree-binding.json", json.dumps(binding, indent=2, sort_keys=True) + "\n")
    files["candidate.bundle"] = hashlib.sha256((out / "candidate.bundle").read_bytes()).hexdigest()
    (out / "manifest.json").write_text(json.dumps({
        "schema": "fm-bench-archive.v1", "sample": slug,
        "identity": {"track": track_name, "role": role, "candidate": candidate, "packet": packet},
        "attempt": {"id": "attempt-1", "status": "scored", "supersedes": None},
        "groups": {
            "packet_and_ground_truth": ["packet.md", "ground-truth.md"],
            "candidate_bundle_and_projection": ["candidate.bundle", "projection.diff"],
            "tree_binding": ["tree-binding.json"], "transcript": ["transcript.md"],
            "capture_and_scoring": ["capture.json", "scoring.py"],
            "judging": ["judging.json"], "timing_cost_quota": ["timing.json"],
            "key_and_verdict": ["verdict.md"]},
        "files": files,
        "tree_binding": binding,
        "evaluator_rerun": {"argv": ["scoring.py"], "scored_inputs": ["work.json"],
                             "input_perturbations": {"work.json": {"kind": "json-value", "pointer": "/value"}},
                             "result_hash": hashlib.sha256((slug + "\n").encode()).hexdigest()},
    }, indent=2, sort_keys=True) + "\n")
PY
  [ -z "$RESTORE_MECHANISM" ] || write_restore_confinement "$bench"
}

BENCH="$TMP_ROOT/archive"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo"
out=$(run_gate "$BENCH" archive-verify) || fail "the complete archive must verify: $out"
assert_contains "$out" "8 evidence groups" "every archive carries all eight evidence groups"
pass "one content-addressed archive per scored output verifies against its stored bytes"

ATTEMPT_BENCH="$TMP_ROOT/archive-attempts"
write_plan "$ATTEMPT_BENCH"
python3 - "$BENCH/archive" "$ATTEMPT_BENCH/archive" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(source, target)
terminal = sorted(path for path in target.iterdir() if path.is_dir())[0]
manifest_path = terminal / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["attempt"]["id"] = "attempt-scored"
manifest["attempt"]["supersedes"] = "attempt-void-2"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
timing = {
    "intervals": {
        "dispatch_accepted_to_first_valid_final_commit": 1200,
        "first_assistant_event_to_first_valid_final_commit": 1100,
    },
    "failure": {"status": "void", "blocker_class": False, "class": "provider_outage"},
}
payload = (json.dumps(timing, indent=2, sort_keys=True) + "\n").encode()
for number, supersedes in ((1, None), (2, "attempt-void-1")):
    void = target / f"{terminal.name}-void-{number}"
    void.mkdir()
    (void / "timing.json").write_bytes(payload)
    (void / "manifest.json").write_text(json.dumps({
        "schema": "fm-bench-archive.v1",
        "sample": void.name,
        "identity": manifest["identity"],
        "attempt": {"id": f"attempt-void-{number}", "status": "void", "supersedes": supersedes},
        "groups": {"failure_and_timing": ["timing.json"]},
        "files": {"timing.json": hashlib.sha256(payload).hexdigest()},
        "tree_binding": {},
    }, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$ATTEMPT_BENCH" archive-verify) \
  || fail "a retained void plus its linked terminal rerun must verify: $out"
assert_contains "$out" "void attempt preserves only content-addressed failure and timing evidence" \
  "void attempts require no fabricated judging or capture facts"
assert_contains "$out" "terminal scored attempt for each of" \
  "prior void attempts do not inflate planned sample coverage"
pass "archive identity preserves a void-to-void-to-scored attempt chain"

UNLINKED_ATTEMPT_BENCH="$TMP_ROOT/archive-unlinked-attempt"
write_plan "$UNLINKED_ATTEMPT_BENCH"
python3 - "$ATTEMPT_BENCH/archive" "$UNLINKED_ATTEMPT_BENCH/archive" <<'PY'
import json, shutil, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(source, target)
terminal = sorted(path for path in target.iterdir() if path.is_dir() and not path.name.endswith("-void"))[0]
manifest_path = terminal / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["attempt"]["supersedes"] = None
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$UNLINKED_ATTEMPT_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "a retained void without an explicit rerun link is refused"
assert_contains "$out" "unresolved void attempts attempt-void-2" "the unlinked attempt is named"
pass "every retained void must be linked to its scored rerun"

FORKED_ATTEMPT_BENCH="$TMP_ROOT/archive-forked-attempt"
write_plan "$FORKED_ATTEMPT_BENCH"
python3 - "$ATTEMPT_BENCH/archive" "$FORKED_ATTEMPT_BENCH/archive" <<'PY'
import json, shutil, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(source, target)
def chain_sample(root, attempt_id):
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        document = json.loads((path / "manifest.json").read_text())
        if document["attempt"]["id"] == attempt_id:
            return path
    raise SystemExit(f"no archived sample carries attempt {attempt_id}")

terminal = chain_sample(target, "attempt-scored")
manifest_path = terminal / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["attempt"]["supersedes"] = "attempt-void-1"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$FORKED_ATTEMPT_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "two reruns cannot fork from one void attempt"
assert_contains "$out" "forked void attempts attempt-void-1" "the forked attempt is named"
pass "archive attempt chains refuse forks"

DANGLING_ATTEMPT_BENCH="$TMP_ROOT/archive-dangling-attempt"
write_plan "$DANGLING_ATTEMPT_BENCH"
python3 - "$ATTEMPT_BENCH/archive" "$DANGLING_ATTEMPT_BENCH/archive" <<'PY'
import json, shutil, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(source, target)
def chain_sample(root, attempt_id):
    for path in sorted(root.iterdir()):
        if not path.is_dir():
            continue
        document = json.loads((path / "manifest.json").read_text())
        if document["attempt"]["id"] == attempt_id:
            return path
    raise SystemExit(f"no archived sample carries attempt {attempt_id}")

terminal = chain_sample(target, "attempt-scored")
manifest_path = terminal / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["attempt"]["supersedes"] = "absent-attempt"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$DANGLING_ATTEMPT_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "a rerun cannot supersede an absent attempt"
assert_contains "$out" "dangling supersession links attempt-scored->absent-attempt" \
  "the dangling link is named"
pass "archive attempt chains refuse dangling links"

CYCLIC_ATTEMPT_BENCH="$TMP_ROOT/archive-cyclic-attempt"
write_plan "$CYCLIC_ATTEMPT_BENCH"
python3 - "$ATTEMPT_BENCH/archive" "$CYCLIC_ATTEMPT_BENCH/archive" <<'PY'
import json, shutil, sys
from pathlib import Path
source, target = Path(sys.argv[1]), Path(sys.argv[2])
shutil.copytree(source, target)
first_void = next(
    path
    for path in sorted(target.iterdir())
    if path.is_dir() and json.loads((path / "manifest.json").read_text())["attempt"]["id"] == "attempt-void-1"
)
manifest_path = first_void / "manifest.json"
manifest = json.loads(manifest_path.read_text())
manifest["attempt"]["supersedes"] = "attempt-void-2"
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$CYCLIC_ATTEMPT_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "void attempts cannot form a supersession cycle"
assert_contains "$out" "cyclic attempt links attempt-void-1, attempt-void-2" \
  "the cyclic attempts are named"
pass "archive attempt chains refuse cycles"

copy_archive_fixture() {  # <source-bench> <target-bench>
  local source=$1 target=$2
  write_plan "$target"
  python3 - "$source/archive" "$target/archive" <<'PY'
import shutil, sys
shutil.copytree(sys.argv[1], sys.argv[2])
PY
}

IDENTITY_BENCH="$TMP_ROOT/archive-identity"
copy_archive_fixture "$BENCH" "$IDENTITY_BENCH"
python3 - "$IDENTITY_BENCH" <<'PY'
import json, sys
from pathlib import Path
samples = sorted(path for path in (Path(sys.argv[1]) / "archive").iterdir() if path.is_dir())
first = json.loads((samples[0] / "manifest.json").read_text())
second_path = samples[1] / "manifest.json"
second = json.loads(second_path.read_text())
second["identity"] = first["identity"]
second_path.write_text(json.dumps(second, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$IDENTITY_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "duplicate archive identities cannot satisfy planned sample coverage"
assert_contains "$out" "archive.identity_coverage fail" "coverage is checked from structured identities"
assert_contains "$out" "duplicate" "the duplicated planned sample identity is named"
assert_contains "$out" "missing" "the displaced planned sample identity is named"
pass "archive coverage requires the exact unique planned sample set"

ROOT_LINK_BENCH="$TMP_ROOT/archive-root-link"
copy_archive_fixture "$BENCH" "$ROOT_LINK_BENCH"
python3 - "$ROOT_LINK_BENCH" <<'PY'
import sys
from pathlib import Path
bench = Path(sys.argv[1])
sample = sorted(path for path in (bench / "archive").iterdir() if path.is_dir())[0]
outside = bench / "external-sample"
sample.rename(outside)
sample.symlink_to(outside, target_is_directory=True)
PY
out=$(run_gate "$ROOT_LINK_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "a symlinked archive sample root is refused"
assert_contains "$out" "archive.storage fail" "archive storage validates roots without following links"
assert_contains "$out" "sample roots are symlinks or special files" "the unsafe root type is named"
pass "archive sample roots must be self-contained real directories"

ARCHIVE_LINK_BENCH="$TMP_ROOT/archive-directory-link"
write_plan "$ARCHIVE_LINK_BENCH"
python3 - "$BENCH/archive" "$ARCHIVE_LINK_BENCH" <<'PY'
import sys
from pathlib import Path
source, bench = Path(sys.argv[1]), Path(sys.argv[2])
(bench / "archive").symlink_to(source, target_is_directory=True)
PY
out=$(run_gate "$ARCHIVE_LINK_BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a symlinked archive directory cannot receive a drill receipt"
assert_contains "$out" "restore.archive_root fail" "the restore checks archive custody before writing"
assert_absent "$BENCH/archive/restore-drill.json" "the external archive receives no receipt through the symlink"
pass "the archive directory itself must remain inside the benchmark"

GROUP_BENCH="$TMP_ROOT/archive-group-roles"
copy_archive_fixture "$BENCH" "$GROUP_BENCH"
python3 - "$GROUP_BENCH" <<'PY'
import json, sys
from pathlib import Path
sample = sorted(path for path in (Path(sys.argv[1]) / "archive").iterdir() if path.is_dir())[0]
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["groups"] = {name: ["scoring.py"] for name in record["groups"]}
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$GROUP_BENCH" archive-verify) && status=0 || status=$?
expect_code 1 "$status" "one evaluator file cannot stand in for every archive evidence role"
assert_contains "$out" "archive evidence groups are not role-specific" "group labels require their own artifacts"
assert_contains "$out" "files reused across evidence roles" "cross-role file reuse is named"
pass "archive evidence groups enforce distinct role-specific artifacts"

out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "cleanup before a restore drill is refused"
assert_contains "$out" "cleanup stays refused" "cleanup needs a drill first"
pass "candidate and snapshot cleanup is refused until a restore drill passes"

if [ -n "$RESTORE_MECHANISM" ]; then
out=$(run_gate "$BENCH" restore-drill) || fail "the restore drill must pass: $out"
assert_contains "$out" "restored into a fresh repository, and rebound to its archived tree" \
  "each bundle is really restored and rebound"
assert_present "$BENCH/archive/restore-drill.json" "the drill writes its receipt"
assert_contains "$out" "shared one preparation pipeline" \
  "the genuine and perturbed replays expose only the declared input difference"
assert_contains "$out" "evaluator_dependence ok proven" \
  "the evaluator responds to its declared scored subset rather than the first restored file"
python3 - "$BENCH" <<'PY' || fail "the receipt must record its bounded deterministic evaluator sample"
import json, sys
from pathlib import Path
bench = Path(sys.argv[1])
receipt = json.loads((bench / "archive" / "restore-drill.json").read_text())
expected = sorted(path.name for path in (bench / "archive").iterdir() if path.is_dir())[:1]
if receipt.get("evaluator_samples") != expected:
    raise SystemExit(f"expected evaluator sample {expected}, got {receipt.get('evaluator_samples')}")
dependence = receipt.get("evaluator_dependence")
if dependence != {expected[0]: {"overall": "proven", "inputs": {"work.json": "proven"}}}:
    raise SystemExit(f"expected proven dependence for {expected[0]}, got {receipt.get('evaluator_dependence')}")
PY
out=$(run_gate "$BENCH" cleanup-gate) || fail "cleanup must pass after a drill: $out"
assert_contains "$out" "no candidate ships directly" "the disposition is re-asserted at cleanup"
pass "the restore drill authorises cleanup only after really restoring every bundle"

NO_GIT_BIN="$TMP_ROOT/no-git-bin"
mkdir -p "$NO_GIT_BIN"
ln -s "$(command -v bash)" "$NO_GIT_BIN/bash"
ln -s "$(command -v dirname)" "$NO_GIT_BIN/dirname"
ln -s "$(command -v python3)" "$NO_GIT_BIN/python3"
out=$(PATH="$NO_GIT_BIN" "$GATE" --bench "$BENCH" restore-drill 2>&1) && status=0 || status=$?
expect_code 1 "$status" "a drill without git is refused"
assert_contains "$out" "git is required" "the missing restore dependency is named"
assert_absent "$BENCH/archive/restore-drill.json" "a refused drill revokes its previous receipt"
out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "cleanup remains refused after a drill loses git"
assert_contains "$out" "no restore drill receipt" "the stale drill clearance cannot survive a refusal"
pass "every restore-drill attempt structurally revokes stale clearance"

fi

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
  if [ "$kind" = symlink ]; then
    assert_contains "$out" "symlinks or special files" "$label path is rejected by file type"
  else
    assert_contains "$out" "escapes sample archive" "$label path is kept inside its own sample archive"
  fi
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

out=$("$CONFINE" --mechanism sandbox-exec --allow "$TMP_ROOT" -- /bin/true 2>&1) && status=0 || status=$?
expect_code 2 "$status" "the unusable sandbox-exec mechanism is rejected"
assert_contains "$out" "unknown mechanism sandbox-exec" "an aborting mechanism cannot be mistaken for confinement"
pass "the benchmark confinement wrapper rejects sandbox-exec"

BENCH="$TMP_ROOT/archive"
write_restore_confinement "$BENCH" none
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "the restore drill must reject a non-enforcing wrapper"
assert_contains "$out" "enforcing confinement mechanism, not none" \
  "the non-enforcing mechanism cannot execute archived code"
assert_absent "$BENCH/archive/restore-drill.json" "a non-enforcing wrapper writes no cleanup receipt"
pass "restore drill rejects an unconfined evaluator fallback"
[ -z "$RESTORE_MECHANISM" ] || write_restore_confinement "$BENCH"

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
pass "every archive statically declares a content-addressed evaluator"

BENCH="$TMP_ROOT/archive-malformed-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-malformed-evaluator"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["argv"] = ["scoring.py", "capture.json"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an arbitrary archived command line is refused"
assert_contains "$out" "exactly one executable evaluator file" "the evaluator interface is fixed before execution"
assert_absent "$BENCH/archive/restore-drill.json" "a malformed evaluator declaration writes no receipt"
pass "the restore drill rejects arbitrary evaluator commands portably"

BENCH="$TMP_ROOT/archive-unvalidated-later-sample"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-unvalidated-later-sample"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[1]
d = json.loads(p.read_text())
d.pop("evaluator_rerun")
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an unselected sample without an evaluator declaration is refused"
assert_contains "$out" "has no deterministic evaluator rerun" "every sample is validated, not only the executed sample"
assert_absent "$BENCH/archive/restore-drill.json" "an incomplete later sample writes no receipt"
pass "bounded execution still validates every archived evaluator declaration"

if [ -n "$RESTORE_MECHANISM" ]; then

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
record["evaluator_rerun"] = {
    "argv": ["scoring.sh"],
    "scored_inputs": ["work.json"],
    "input_perturbations": {"work.json": {"kind": "json-value", "pointer": "/value"}},
    "result_hash": hashlib.sha256((sample / "capture.json").read_bytes()).hexdigest(),
}
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an archived-file echo cannot stand in for a restored-tree evaluator"
assert_contains "$out" "ignored declared scored input work.json" \
  "the rerun contract proves evaluator dependence on restored content"
assert_absent "$BENCH/archive/restore-drill.json" "a no-op evaluator writes no cleanup receipt"
pass "the restore drill refuses an executable evaluator that ignores restored content"

BENCH="$TMP_ROOT/archive-real-content-inputs"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-real-content-inputs"
python3 - "$BENCH" <<'PY'
import hashlib, json, struct, sys, zlib
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text(
    '#!/bin/sh\ncat "$1/work.ts" "$1/work.css" "$1/work.html" "$1/work.png" "$1/.ignored-by-evaluator"\n'
)
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = [
    "./work.ts",
    "work.css",
    "work.html",
    "work.png",
    ".ignored-by-evaluator",
]
record["evaluator_rerun"]["input_perturbations"] = {
    "work.ts": {"kind": "text-token", "token": record["sample"]},
    "work.css": {"kind": "text-token", "token": record["sample"]},
    "work.html": {"kind": "text-token", "token": record["sample"]},
    "work.png": {"kind": "png-pixel", "x": 0, "y": 0, "channel": 0},
}
png_chunks = []
for kind, payload in (
    (b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)),
    (b"IDAT", zlib.compress(b"\x00\x20\x40\x60", level=0)),
    (b"IEND", b""),
):
    png_chunks.append(
        struct.pack(">I", len(payload))
        + kind
        + payload
        + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
    )
slug = record["sample"]
genuine = (
    f'export default "{slug}";\n'.encode()
    + f'.sample::after {{ content: "{slug}"; }}\n'.encode()
    + f'<main data-sample="{slug}">candidate</main>\n'.encode()
    + b"\x89PNG\r\n\x1a\n"
    + b"".join(png_chunks)
    + b"not scored\n"
)
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(genuine).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) || fail "real benchmark content must support dependence proof: $out"
assert_contains "$out" "work.ts proven by its declared form-preserving perturbation" \
  "a normalized TypeScript declaration proves dependence"
assert_contains "$out" "work.css proven by its declared form-preserving perturbation" \
  "CSS content proves dependence"
assert_contains "$out" "work.html proven by its declared form-preserving perturbation" \
  "HTML content proves dependence"
assert_contains "$out" "work.png proven by its declared form-preserving perturbation" \
  "PNG content proves dependence"
assert_contains "$out" ".ignored-by-evaluator unproven; another scored input supplies the required dependence proof" \
  "unproven is retained only as a per-input state beside a real proof"
python3 - "$BENCH" <<'PY' || fail "the receipt must preserve proven and per-input unproven states"
import json, sys
from pathlib import Path
receipt = json.loads((Path(sys.argv[1]) / "archive" / "restore-drill.json").read_text())
sample = receipt["evaluator_samples"][0]
record = receipt["evaluator_dependence"][sample]
expected = {
    ".ignored-by-evaluator": "unproven",
    "work.css": "proven",
    "work.html": "proven",
    "work.png": "proven",
    "work.ts": "proven",
}
if record != {"overall": "proven", "inputs": expected}:
    raise SystemExit(f"unexpected dependence receipt: {record}")
PY
out=$(run_gate "$BENCH" cleanup-gate) || fail "mixed proven and unproven inputs must preserve cleanup proofs: $out"
pass "TypeScript, CSS, HTML, and PNG prove dependence through pure-data declarations"

BENCH="$TMP_ROOT/archive-metadata-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-metadata-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
if find "$1" -type f -newer "$1/work.json" -print -quit | grep -q .; then
  printf 'metadata\n'
else
  printf 'perturbed\n'
fi
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"metadata\n").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "candidate metadata cannot reveal which differential input was perturbed"
assert_contains "$out" "ignored declared scored input work.json" \
  "identical prepared-tree metadata makes a content-blind evaluator input-invariant"
assert_absent "$BENCH/archive/restore-drill.json" "a metadata-only evaluator writes no cleanup receipt"
pass "differential evaluator trees expose identical normalized metadata"

BENCH="$TMP_ROOT/archive-size-only-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-size-only-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
if [ "$(stat -c %s "$1/work-number.json")" = 8 ]; then
  printf 'genuine\n'
else
  printf 'perturbed\n'
fi
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["work-number.json"]
record["evaluator_rerun"]["input_perturbations"] = {
    "work-number.json": {"kind": "json-value", "pointer": "/n"}
}
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"genuine\n").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "input byte length cannot identify the differential role"
assert_contains "$out" "ignored declared scored input work-number.json" \
  "equal-size prepared inputs make a size-only evaluator input-invariant"
assert_absent "$BENCH/archive/restore-drill.json" "a size-only evaluator writes no cleanup receipt"
pass "every declared input has equal prepared size in both runs"

BENCH="$TMP_ROOT/archive-length-changing-perturbation"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-length-changing-perturbation"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text('#!/bin/sh\ncat "$1/work-bool.json"\n')
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["work-bool.json"]
record["evaluator_rerun"]["input_perturbations"] = {
    "work-bool.json": {"kind": "json-value", "pointer": "/value"}
}
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b'{"value":true}\n').hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a length-changing declared perturbation is refused"
assert_contains "$out" "cannot preserve its serialized byte length" \
  "the gate names a JSON scalar that cannot satisfy the equal-size invariant"
assert_absent "$BENCH/archive/restore-drill.json" "a length-changing perturbation writes no cleanup receipt"
pass "length-changing declarations cannot bypass the prepared-tree size invariant"

BENCH="$TMP_ROOT/archive-role-name-input"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-role-name-input"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text('#!/bin/sh\ncat "$1/genuine"\n')
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["genuine"]
record["evaluator_rerun"]["input_perturbations"] = {
    "genuine": {"kind": "json-value", "pointer": "/value"}
}
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(
    json.dumps({"value": sample.name}, indent=2, sort_keys=True).encode() + b"\n"
).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) || fail "a scored input may share a name with an execution role: $out"
assert_contains "$out" "genuine proven by its declared form-preserving perturbation" \
  "candidate paths cannot collide with differential execution roles"
pass "differential execution results use a collision-free key space"

BENCH="$TMP_ROOT/archive-png-encoding-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-png-encoding-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
count=$(grep -ao IDAT "$1/work.png" | wc -l | tr -d ' ')
if [ "$count" = 2 ]; then
  printf 'genuine\n'
else
  printf 'perturbed\n'
fi
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["work.png"]
record["evaluator_rerun"]["input_perturbations"] = {
    "work.png": {"kind": "png-pixel", "x": 0, "y": 0, "channel": 0}
}
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"genuine\n").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "PNG chunk layout cannot identify the differential role"
assert_contains "$out" "does not match" \
  "the genuine hash is measured over the same deterministic PNG encoding as its perturbation"
assert_absent "$BENCH/archive/restore-drill.json" "a PNG-encoding classifier writes no cleanup receipt"
pass "PNG differential copies share one deterministic encoding pipeline"

BENCH="$TMP_ROOT/archive-overbroad-perturbation"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-overbroad-perturbation"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text('#!/bin/sh\ncat "$1/work-link.json"\n')
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["work-link.json"]
record["evaluator_rerun"]["input_perturbations"] = {
    "work-link.json": {"kind": "json-value", "pointer": "/value"}
}
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(
    json.dumps({"value": record["sample"]}, indent=2, sort_keys=True).encode() + b"\n"
).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a perturbation that changes a path outside its declaration is refused"
assert_contains "$out" "differ outside the declared perturbation" \
  "the complete prepared-root byte invariant catches a symlink-amplified write"
assert_absent "$BENCH/archive/restore-drill.json" "an over-broad perturbation writes no cleanup receipt"
pass "the prepared-tree byte and metadata invariant can fail closed"

BENCH="$TMP_ROOT/archive-stateful-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-stateful-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("#!/bin/sh\ncat counter 2>/dev/null\nprintf x >> counter\n")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "per-run evaluator state cannot impersonate scored-input dependence"
assert_contains "$out" "ignored declared scored input work.json" \
  "fresh scratch state makes both input-ignoring evaluator results identical"
assert_absent "$BENCH/archive/restore-drill.json" "a stateful no-op evaluator writes no cleanup receipt"
pass "differential evaluator runs use independent scratch state"

BENCH="$TMP_ROOT/archive-self-identifying-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-self-identifying-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
surface="$PWD:$1:${HOME-}:${TMPDIR-}:${BENCH_PRIVATE_ROOT-}:${BENCH_PRIVATE_HOME-}:${BENCH_PRIVATE_TMP-}"
case "$surface" in
  *genuine*) printf 'genuine\\n' ;;
  *perturbed*) printf 'perturbed\\n' ;;
  *) printf 'blind\\n' ;;
esac
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"blind\n").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "run paths and environments cannot reveal differential roles"
assert_contains "$out" "ignored declared scored input work.json" \
  "opaque roots make a role-sniffing evaluator input-invariant"
assert_absent "$BENCH/archive/restore-drill.json" "a self-identifying evaluator writes no cleanup receipt"
pass "differential evaluator runs hide their role in paths and environment"

BENCH="$TMP_ROOT/archive-fixed-marker-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-fixed-marker-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
if grep -qr fm-bench-restore-perturbation "$1" 2>/dev/null; then
  printf 'perturbed\\n'
else
  printf 'genuine\\n'
fi
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(b"genuine\n").hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "recognising an old perturbation marker cannot impersonate evaluation"
assert_contains "$out" "ignored declared scored input work.json" \
  "fresh structured perturbation reveals the marker-sniffing no-op"
assert_absent "$BENCH/archive/restore-drill.json" "a marker-sniffing evaluator writes no cleanup receipt"
pass "structured differential perturbations carry no fixed recognizable marker"

fi

BENCH="$TMP_ROOT/archive-no-perturbable-input"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-no-perturbable-input"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("#!/bin/sh\ncat \"$1/work.ts\"\n")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["scored_inputs"] = ["work.ts"]
record["evaluator_rerun"].pop("input_perturbations")
record["evaluator_rerun"]["result_hash"] = hashlib.sha256(
    f'export default "{record["sample"]}";\n'.encode()
).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an evaluator with no perturbable scored input is refused"
assert_contains "$out" "must declare at least one supported form-preserving scored-input perturbation" \
  "dependence cannot be skipped by omitting the perturbation declaration"
assert_absent "$BENCH/archive/restore-drill.json" "an all-unproven evaluator writes no cleanup receipt"
pass "every archived evaluator proves dependence on at least one scored input"

BENCH="$TMP_ROOT/archive-no-scored-inputs"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-no-scored-inputs"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["scored_inputs"] = []
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an evaluator must declare the restored inputs it scores"
assert_contains "$out" "scored_inputs must name at least one" "an empty scored-input declaration is refused"
assert_absent "$BENCH/archive/restore-drill.json" "an input-free evaluator writes no cleanup receipt"
pass "every archived evaluator declares a non-empty scored-input set"

BENCH="$TMP_ROOT/archive-duplicate-scored-input"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-duplicate-scored-input"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["scored_inputs"] = ["work.json", "work.json"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a scored input cannot reuse one perturbation declaration twice"
assert_contains "$out" "scored_inputs must not contain duplicates" \
  "the perturbation contract is one-to-one"
assert_absent "$BENCH/archive/restore-drill.json" "a duplicate scored input writes no cleanup receipt"
pass "scored-input perturbation declarations are one-to-one"

BENCH="$TMP_ROOT/archive-invalid-perturbation-pointer"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-invalid-perturbation-pointer"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["input_perturbations"]["work.json"]["pointer"] = "/missing"
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a perturbation pointer must resolve in the scored input"
assert_contains "$out" "scored input perturbation is invalid for work.json" \
  "the gate proves the declared mutation applies to the restored input"
assert_absent "$BENCH/archive/restore-drill.json" "an invalid perturbation pointer writes no cleanup receipt"
pass "scored-input perturbation pointers are validated against restored content"

BENCH="$TMP_ROOT/archive-oversized-png"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-oversized-png" oversized
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["scored_inputs"] = ["work.png"]
d["evaluator_rerun"]["input_perturbations"] = {
    "work.png": {"kind": "png-pixel", "x": 0, "y": 0, "channel": 0}
}
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an oversized PNG is refused before its compressed raster is allocated"
assert_contains "$out" "safe decompression limit" "the bounded PNG refusal names its resource limit"
assert_absent "$BENCH/archive/restore-drill.json" "an oversized PNG writes no cleanup receipt"
pass "untrusted PNG scored inputs are bounded before decompression"

BENCH="$TMP_ROOT/archive-executable-perturbation"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-executable-perturbation"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["input_perturbations"]["work.json"]["argv"] = ["mutate-input"]
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "an executable perturbation declaration is refused"
assert_contains "$out" "json-value accepts only kind and pointer" \
  "the gate accepts only its own pure-data perturbation schema"
assert_absent "$BENCH/archive/restore-drill.json" "an executable perturbation writes no cleanup receipt"
pass "archived evaluators cannot supply code for their dependence perturbation"

BENCH="$TMP_ROOT/archive-escaping-scored-input"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-escaping-scored-input"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
p = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
d = json.loads(p.read_text())
d["evaluator_rerun"]["scored_inputs"] = ["../outside.txt"]
d["evaluator_rerun"]["input_perturbations"] = {
    "../outside.txt": {"kind": "json-value", "pointer": "/value"}
}
p.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a declared scored input cannot escape the restored candidate"
assert_contains "$out" "path is not a contained relative path" "the escaping scored-input path is refused"
assert_absent "$BENCH/archive/restore-drill.json" "an escaping scored-input declaration writes no cleanup receipt"
pass "declared scored inputs stay inside the restored candidate"

if [ -n "$RESTORE_MECHANISM" ]; then

BENCH="$TMP_ROOT/archive-perturbation-inconclusive"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-perturbation-inconclusive"
python3 - "$BENCH" <<'PY'
import hashlib, json, shlex, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
scoring = sample / "scoring.py"
expected = shlex.quote(record["sample"])
scoring.write_text(f"""#!/bin/sh
value=$(sed -n 's/^[[:space:]]*\"value\":[[:space:]]*\"\\([^\"]*\\)\".*$/\\1/p' \"$1/work.json\")
if [ \"$value\" != {expected} ]; then
  printf 'valid JSON but unsupported value\n' >&2
  exit 9
fi
printf '%s\n' \"$value\"
""")
scoring.chmod(0o755)
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
expect_code 1 "$status" "a rejected form-preserving perturbation is inconclusive"
assert_contains "$out" "was inconclusive because the declared form-preserving input" \
  "a parser rejection is distinguished from input invariance"
assert_not_contains "$out" "ignored declared scored input" \
  "a failed perturbation is not mislabeled as a no-op evaluator"
assert_absent "$BENCH/archive/restore-drill.json" "an inconclusive perturbation writes no cleanup receipt"
pass "perturbation failures are inconclusive rather than invariant"

BENCH="$TMP_ROOT/archive-scratch-evaluator"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-scratch-evaluator"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text("""#!/bin/sh
printf 'scratch\\n' > scratch-only.txt
sed -n 's/^[[:space:]]*"value":[[:space:]]*"\\([^"]*\\)".*$/\\1/p' "$1/work.json"
cat scratch-only.txt
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["evaluator_rerun"]["result_hash"] = hashlib.sha256((record["sample"] + "\nscratch\n").encode()).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) || fail "an evaluator that writes scratch output must not dirty its archive: $out"
assert_contains "$out" "evaluator_dependence ok proven" "the scratch-writing evaluator ran against both restored candidates"
first_sample=$(find "$BENCH/archive" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
assert_absent "$first_sample/scratch-only.txt" "evaluator scratch output never reaches the certified archive"
out=$(run_gate "$BENCH" cleanup-gate) || fail "a scratch-only evaluator must leave cleanup authorised: $out"
pass "archived evaluators rerun in scratch rather than certified storage"

BENCH="$TMP_ROOT/archive-post-rerun"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-post-rerun"
python3 - "$BENCH" <<'PY'
import hashlib, json, shlex, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "scoring.py"
scoring.write_text(f"""#!/bin/sh
printf 'dirty\\n' > {shlex.quote(str(sample / 'archive-dirty.txt'))}
sed -n 's/^[[:space:]]*"value":[[:space:]]*"\\([^"]*\\)".*$/\\1/p' "$1/work.json"
""")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"]["scoring.py"] = hashlib.sha256(scoring.read_bytes()).hexdigest()
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" restore-drill) || fail "the confined evaluator must not reach the certified archive: $out"
dirty_sample=$(find "$BENCH/archive" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
assert_absent "$dirty_sample/archive-dirty.txt" \
  "the certified archive is outside the evaluator confinement"
out=$(run_gate "$BENCH" cleanup-gate) || fail "an unreachable archive mutation must leave cleanup authorised: $out"
pass "confined archived evaluators cannot dirty certified evidence"

BENCH="$TMP_ROOT/archive-stability"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-stability"
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
scoring = sample / "stability-wait-evaluator.sh"
scoring.write_text("#!/bin/sh\nsleep 3\nsed -n 's/^{\"value\":\"\\([^\"]*\\)\"}$/\\1/p' \"$1/work.json\"\n")
scoring.chmod(0o755)
manifest = sample / "manifest.json"
record = json.loads(manifest.read_text())
record["files"][scoring.name] = hashlib.sha256(scoring.read_bytes()).hexdigest()
record["groups"]["capture_and_scoring"].append(scoring.name)
record["evaluator_rerun"]["argv"] = [scoring.name]
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
stability_out="$TMP_ROOT/archive-stability.out"
run_gate "$BENCH" restore-drill >"$stability_out" 2>&1 &
stability_pid=$!
if ! python3 - "$stability_pid" stability-wait-evaluator.sh <<'PY'
import subprocess, sys, time

root = int(sys.argv[1])
marker = sys.argv[2]
while True:
    rows = []
    output = subprocess.check_output(
        ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "stat=", "-o", "command="],
        text=True,
    )
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            rows.append((int(fields[0]), int(fields[1]), fields[2], fields[3]))
    descendants = {root}
    changed = True
    while changed:
        changed = False
        for pid, parent, _, _ in rows:
            if parent in descendants and pid not in descendants:
                descendants.add(pid)
                changed = True
    if any(pid in descendants and marker in command for pid, _, _, command in rows):
        raise SystemExit(0)
    root_rows = [row for row in rows if row[0] == root]
    if not root_rows or root_rows[0][2].startswith("Z"):
        raise SystemExit(1)
    time.sleep(0.1)
PY
then
  wait "$stability_pid" || true
  fail "the archive-stability evaluator never started"
fi
printf 'changed during drill\n' >> "$BENCH/archive/a-a1-fable-5-high/verdict.md"
wait "$stability_pid" && status=0 || status=$?
out=$(cat "$stability_out")
expect_code 1 "$status" "an archive change during evaluator replay is refused"
assert_contains "$out" "restore.archive_stability fail" "the post-rerun digest detects concurrent archive change"
assert_absent "$BENCH/archive/restore-drill.json" "an unstable archive writes no cleanup receipt"
pass "the restore drill refuses an archive that changes during replay"

BENCH="$TMP_ROOT/archive-binding"
write_plan "$BENCH"
write_archive "$BENCH" "$TMP_ROOT/srcrepo-binding"
out=$(run_gate "$BENCH" restore-drill) || fail "the binding fixture needs a genuine drill receipt: $out"
out=$(run_gate "$BENCH" cleanup-gate) || fail "a genuine drill receipt must authorise cleanup before mutation: $out"
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path

manifest = sorted((Path(sys.argv[1]) / "archive").glob("*/manifest.json"))[0]
record = json.loads(manifest.read_text())
record["tree_binding"]["base_tree"] = "f" * 40
manifest.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" cleanup-gate) && status=0 || status=$?
expect_code 1 "$status" "editing a manifest binding after a genuine drill withdraws cleanup"
assert_contains "$out" "changed after the restore drill" "the gate-written receipt binds manifest bytes"
pass "a changed archive manifest withdraws genuine cleanup authority"

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

fi

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

if [ -z "$RESTORE_MECHANISM" ]; then
  BENCH="$TMP_ROOT/archive"
  write_restore_confinement "$BENCH" bwrap
  out=$(run_gate "$BENCH" restore-drill) && status=0 || status=$?
  expect_code 1 "$status" "the restore drill must fail closed without a proven confinement"
  assert_contains "$out" "bwrap is not installed" \
    "the unavailable confinement requirement is named"
  assert_absent "$BENCH/archive/restore-drill.json" "an unconfined evaluator run writes no cleanup receipt"
  pass "restore drill refuses when this host has no enforcing confinement"
fi

# --- the corrected promotion rule -------------------------------------------

write_results() {  # <bench-dir> <mode>
  local bench=$1 mode=$2
  python3 - "$bench" "$mode" <<'PY'
import json, sys
from pathlib import Path

bench, mode = Path(sys.argv[1]), sys.argv[2]
plan = json.loads((bench / "benchmark.json").read_text())
out = bench / "results"
archive = bench / "archive"
if out.is_dir():
    for stale in out.glob("*.json"):
        stale.unlink()
out.mkdir(exist_ok=True)
if archive.is_dir():
    import shutil
    shutil.rmtree(archive)
archive.mkdir()
winners = {"A": "Fable 5 High", "B": "Terra 5.6 High", "C": "GPT 5.6 Sol High"}

def write(
    track,
    packet,
    candidate,
    role,
    composite,
    status="scored",
    blocker=False,
    suffix="",
    supersedes=None,
    attempt_id=None,
):
    slug = f"{track}-{packet}-{candidate}{suffix}".lower().replace(" ", "-").replace(".", "-")
    sample = archive / slug
    sample.mkdir()
    tree = __import__("hashlib").sha1(slug.encode()).hexdigest()
    judges = [judge["name"] for judge in plan["tracks"][track]["judges"]]
    evidence = {
        "timing.json": {"intervals": {
            "dispatch_accepted_to_first_valid_final_commit": 1200,
            "first_assistant_event_to_first_valid_final_commit": 1100,
        }, "failure": {"status": status, "blocker_class": blocker,
                        "class": "none" if status == "scored" else "provider_outage"}},
    }
    if status == "scored":
        evidence.update({
            "judging.json": {"panel": judges, "scores": [composite for _ in judges]},
            "capture.json": {
                "deterministic": composite,
                "tree": tree,
                "capture_hash": __import__("hashlib").sha256((slug + "-capture").encode()).hexdigest(),
            },
        })
    files = {}
    for name, document in evidence.items():
        payload = (json.dumps(document, indent=2, sort_keys=True) + "\n").encode()
        (sample / name).write_bytes(payload)
        files[name] = __import__("hashlib").sha256(payload).hexdigest()
    (sample / "manifest.json").write_text(json.dumps({
        "schema": "fm-bench-archive.v1", "sample": slug,
        "identity": {"track": track, "packet": packet, "candidate": candidate, "role": role},
        "attempt": {"id": attempt_id or ("attempt-void" if status == "void" else "attempt-1"),
                    "status": status, "supersedes": supersedes},
        "groups": {"failure_and_timing": ["timing.json"]} if status == "void" else {},
        "files": files,
        "tree_binding": {"original_tree": tree} if status == "scored" else {},
    }, indent=2, sort_keys=True) + "\n")
    (out / f"{slug}.json").write_text(json.dumps({
        "schema": "fm-bench-result.v1", "archive_sample": slug,
    }, indent=2, sort_keys=True) + "\n")

for name in sorted(plan["tracks"]):
    track = plan["tracks"][name]
    ids = [packet["id"] for packet in track["packets"]]
    for entrant in track["entrants"]:
        win = entrant["name"] == winners[name]
        for index, packet in enumerate(ids):
            if win and mode == "unreplaced_void" and index == 0:
                write(name, packet, entrant["name"], "entrant", 0.0, status="void")
                continue
            score = 9.0 if win else 7.0
            blocker = False
            if win and mode == "split" and index == 2:
                score = 6.0
            if win and mode == "blocker" and index == 1:
                blocker = True
            if win and mode == "thin":
                score = 7.5
            if win and mode == "nonfinite":
                score = float("inf")
            if win and mode == "outofscale":
                score = 11.0
            supersedes = "attempt-void" if win and mode == "void" and index == 0 else None
            attempt_id = None
            if win and mode == "void_chain" and index == 0:
                supersedes = "attempt-void-2"
                attempt_id = "attempt-scored"
            write(
                name,
                packet,
                entrant["name"],
                "entrant",
                score,
                blocker=blocker,
                supersedes=supersedes,
                attempt_id=attempt_id,
            )
        if win and mode == "void":
            write(name, ids[0], entrant["name"], "entrant", 0.0, status="void", suffix="-void")
        if win and mode == "void_chain":
            write(
                name,
                ids[0],
                entrant["name"],
                "entrant",
                0.0,
                status="void",
                suffix="-void-1",
                attempt_id="attempt-void-1",
            )
            write(
                name,
                ids[0],
                entrant["name"],
                "entrant",
                0.0,
                status="void",
                suffix="-void-2",
                supersedes="attempt-void-1",
                attempt_id="attempt-void-2",
            )
        if win and mode == "ninth":
            write(name, ids[0], entrant["name"], "entrant", 9.0, suffix="-rerun")
    if "baseline" in track:
        for index, packet in enumerate(track["baseline_packets"]):
            if mode == "zero_floor":
                base = 10.0 if index == 0 else 8.5
            elif mode == "negative_mean":
                base = 10.0 if index == 0 else 8.75
            elif mode == "lossbound":
                base = 9.5 if index == 0 else 7.5
            else:
                base = 9.5 if mode == "veto" else 7.5
            if mode == "baseline_nonfinite" and index == 0:
                base = float("inf")
            if mode == "baseline_unreplaced_void" and index == 0:
                write(name, packet, track["baseline"]["name"], "baseline", 0.0, status="void")
                continue
            supersedes = "attempt-void" if mode == "baseline_void" and index == 0 else None
            write(name, packet, track["baseline"]["name"], "baseline", base, supersedes=supersedes)
        if mode == "baseline_void":
            write(
                name,
                track["baseline_packets"][0],
                track["baseline"]["name"],
                "baseline",
                0.0,
                status="void",
                suffix="-void",
            )
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

BENCH="$TMP_ROOT/promote-panel-tamper"
write_plan "$BENCH"
write_results "$BENCH" sweep
python3 - "$BENCH" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench = Path(sys.argv[1])
sample = sorted((bench / "archive").iterdir())[0]
evidence_path = sample / "judging.json"
evidence = json.loads(evidence_path.read_text())
evidence["panel"] = ["candidate-selected judge"]
payload = (json.dumps(evidence, indent=2, sort_keys=True) + "\n").encode()
evidence_path.write_bytes(payload)
manifest = json.loads((sample / "manifest.json").read_text())
manifest["files"]["judging.json"] = hashlib.sha256(payload).hexdigest()
(sample / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "a content-addressed but candidate-specific panel is refused"
assert_contains "$out" "does not bind the common panel" "promotion recomputes the panel from archived evidence"
pass "promotion is bound to the planned neutral panel and archived sample evidence"

BENCH="$TMP_ROOT/promote-unplanned-track"
write_plan "$BENCH"
write_results "$BENCH" sweep
python3 - "$BENCH" <<'PY'
import json, sys
from pathlib import Path
sample = sorted((Path(sys.argv[1]) / "archive").iterdir())[0]
path = sample / "manifest.json"
manifest = json.loads(path.read_text())
manifest["identity"]["track"] = "retired-track"
path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "an unplanned archived track is a named refusal"
assert_contains "$out" "names unplanned track 'retired-track'" \
  "stale track identity cannot reach empty-panel arithmetic"
pass "promotion refuses an unplanned track without a traceback"

BENCH="$TMP_ROOT/promote-sample-link"
write_plan "$BENCH"
write_results "$BENCH" sweep
python3 - "$BENCH" <<'PY'
import sys
from pathlib import Path
bench = Path(sys.argv[1])
sample = sorted((bench / "archive").iterdir())[0]
outside = bench / "external-promotion-evidence"
sample.rename(outside)
sample.symlink_to(outside, target_is_directory=True)
PY
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "promotion refuses a symlinked archive sample root"
assert_contains "$out" "sample root is symlinked" "promotion validates its sample root before evidence"
pass "promotion reads evidence only through real contained sample roots"

BENCH="$TMP_ROOT/promote-composite-contract"
write_plan "$BENCH" 'plan["promotion_rule"]["composite"]["weights"] = {"deterministic": 1.0, "panel": -0.0}'
write_results "$BENCH" sweep
python3 - "$BENCH/benchmark.json" <<'PY'
import json, sys
path = sys.argv[1]
plan = json.load(open(path))
plan["promotion_rule"]["composite"]["weights"]["panel"] = -1
json.dump(plan, open(path, "w"), indent=2, sort_keys=True)
PY
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "promotion independently refuses invalid frozen composite weights"
assert_contains "$out" "promote.composite_rule fail" "promotion reads the plan-owned blend"
pass "promotion cannot invent or bypass the frozen composite blend"

BENCH="$TMP_ROOT/promote-nonfinite"
write_plan "$BENCH"
write_results "$BENCH" nonfinite
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "an infinite entrant composite is refused"
assert_contains "$out" "has no finite numeric composite" "the non-finite entrant score is named"
assert_contains "$out" "no standing route: a composite is not finite" "infinity cannot become a sweeper"
pass "non-finite entrant composites cannot promote"

BENCH="$TMP_ROOT/promote-baseline-nonfinite"
write_plan "$BENCH"
write_results "$BENCH" baseline_nonfinite
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "an infinite baseline composite is refused"
assert_contains "$out" "has no finite numeric composite" "the non-finite baseline score is named"
assert_contains "$out" "no standing route: a composite is not finite" "infinity cannot enter veto arithmetic"
pass "non-finite baseline composites cannot reach regression arithmetic"

BENCH="$TMP_ROOT/promote-replaced-void"
write_plan "$BENCH"
write_results "$BENCH" void
out=$(run_gate "$BENCH" promote-evaluate) || fail "a void with a scored replacement must remain promotable: $out"
assert_contains "$out" "all 1 voided attempts resolve through finite chains to one terminal scored result" \
  "the scored rerun names the void attempt it supersedes"
assert_contains "$out" "standing route eligible" "a replaced void does not make the field permanently incomplete"
pass "a void is retained as evidence and credited when its rerun scores"

BENCH="$TMP_ROOT/promote-void-chain"
write_plan "$BENCH"
write_results "$BENCH" void_chain
out=$(run_gate "$BENCH" promote-evaluate) \
  || fail "two consecutive voids resolved by one scored rerun must remain promotable: $out"
assert_contains "$out" "all 2 voided attempts resolve through finite chains to one terminal scored result" \
  "a void-to-void-to-scored chain resolves to its single terminal attempt"
assert_contains "$out" "standing route eligible" "a second void on one packet does not deadlock the field"
pass "an arbitrarily long finite void chain resolves to one terminal scored attempt"

BENCH="$TMP_ROOT/promote-void-no-result"
write_plan "$BENCH"
write_results "$BENCH" void
rm -f "$BENCH/results/a-a1-fable-5-high-void.json"
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "an archived void with no result record must refuse promotion"
assert_contains "$out" "archived void attempts have no result records: a-a1-fable-5-high-void" \
  "the unaccounted void sample is named"
pass "every archived void attempt must carry its own result record"

BENCH="$TMP_ROOT/promote-replaced-baseline-void"
write_plan "$BENCH"
write_results "$BENCH" baseline_void
out=$(run_gate "$BENCH" promote-evaluate) || fail "a baseline void with a scored replacement must remain promotable: $out"
assert_contains "$out" "resolve through finite chains to one terminal scored result" \
  "the baseline rerun reconciles its retained void"
assert_contains "$out" "standing route eligible" "a replaced baseline void does not make the field incomplete"
pass "baseline void evidence is credited when the same baseline sample reruns"

BENCH="$TMP_ROOT/promote-zero-floor"
write_plan "$BENCH"
write_results "$BENCH" zero_floor
out=$(run_gate "$BENCH" promote-evaluate) || fail "a zero mean delta at the fixed floor must pass: $out"
assert_contains "$out" "mean delta 0.000 >= 0.000" "the zero baseline mean floor is inclusive"
assert_contains "$out" "1 <= 1 losses" "one loss remains within the original outer limit"
pass "the baseline veto accepts its zero-mean and one-loss boundaries"

BENCH="$TMP_ROOT/promote-declared-loss-bound"
write_plan "$BENCH" 'plan["promotion_rule"]["baseline_veto"]["max_losses_of_three"] = 0'
write_results "$BENCH" lossbound
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "a loss beyond the declared zero-loss bound refuses promotion"
assert_contains "$out" "above the declared maximum 0" "the veto reads its declared loss bound"
pass "promotion enforces the frozen baseline loss limit"

BENCH="$TMP_ROOT/promote-loosened-mean-bound"
write_plan "$BENCH" 'plan["promotion_rule"]["baseline_veto"]["max_negative_mean_quality_delta"] = -1000'
write_results "$BENCH" veto
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "promotion refuses a mean bound loosened after plan validation"
assert_contains "$out" "bounds exceed the zero mean floor or one-loss outer limit" \
  "the promotion path independently enforces the hard mean floor"
pass "promotion cannot bypass the baseline mean floor through a plan edit"

BENCH="$TMP_ROOT/promote-loosened-loss-bound"
write_plan "$BENCH" 'plan["promotion_rule"]["baseline_veto"]["max_losses_of_three"] = 3'
write_results "$BENCH" veto
out=$(run_gate "$BENCH" promote-evaluate) && status=0 || status=$?
expect_code 1 "$status" "promotion refuses a loss bound loosened after plan validation"
assert_contains "$out" "bounds exceed the zero mean floor or one-loss outer limit" \
  "the promotion path independently enforces the hard one-loss ceiling"
pass "promotion cannot bypass the baseline loss ceiling through a plan edit"

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
refuses_promotion "a score outside the frozen common scale" outofscale "has no finite numeric composite"
refuses_promotion "a baseline regression" veto "regression veto fired"
refuses_promotion "a negative baseline mean" negative_mean "below the declared floor 0.000"
refuses_promotion "a void with no scored replacement" unreplaced_void "do not resolve to one terminal scored result"
refuses_promotion "a baseline void with no scored replacement" baseline_unreplaced_void "baseline:"
refuses_promotion "an extra sample beyond the approved six" ninth "no adaptive extension"
pass "five of six, blockers, thin margins, regressions, all-role unreplaced voids, and seventh samples refuse"
