#!/usr/bin/env bash
# Contract tests for the planning-to-Linear story sharder mechanics.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHARD="$ROOT/bin/fm-shard.sh"
TMP_ROOT=$(fm_test_tmproot fm-shard)
mkdir -p "$TMP_ROOT"

write_valid_plan() {  # <path>
  cat > "$1" <<'JSON'
{
  "initiative": {
    "key": "fm-story-sharder",
    "title": "Story sharder",
    "team_key": "ONM",
    "project_name": "pm-tools",
    "source": "ONM-1035"
  },
  "spec": {
    "linear": {
      "type": "document",
      "title": "Story sharder SPEC"
    },
    "why": "Make large planning work executable without replacing the normal Linear workflow.",
    "capabilities": [
      {"id": "CAP-INTAKE", "text": "Extend normal Linear intake with explicit sharding when scope is large."},
      {"id": "CAP-APPLY", "text": "Materialize approved stories as Linear issues and backlog work."}
    ],
    "constraints": [
      "SPEC kernels live in Linear.",
      "Routine in-scope work keeps firstmate autonomy."
    ],
    "non_goals": [
      "Do not create a parallel execution tracker."
    ],
    "success_signal": "Approved stories can be spawned through the existing firstmate flow.",
    "companions": [
      {"title": "Decision record", "url": "https://linear.example/decision"}
    ]
  },
  "approval_decision": {
    "title": "Approve story sharder shard",
    "assignee_id": "captain-user-id"
  },
  "milestones": [
    {"id": "M1", "name": "Planning surface", "description": "Create the approval surface."},
    {"id": "M2", "name": "Execution materialization", "description": "Create executable stories."}
  ],
  "stories": [
    {
      "id": "ST-001",
      "title": "Define story shard plan schema",
      "description": "Define the reusable JSON shape used by the mechanics script.",
      "acceptance_criteria": ["The schema captures milestones, dependencies, capabilities, and verification."],
      "verification_contract": "A validation test rejects missing Linear SPEC placement.",
      "dependencies": [],
      "milestone": "M1",
      "worker_kind": "ship",
      "target_project": "firstmate",
      "capabilities": ["CAP-INTAKE"],
      "backlog_id": "fm-story-sharder-schema"
    },
    {
      "id": "ST-002",
      "title": "Materialize approved stories",
      "description": "Create Linear issues and matching backlog tasks after approval.",
      "acceptance_criteria": ["Dependencies become Linear relations and backlog blocked-by edges."],
      "verification_contract": "Dry-run output shows the dependency edge before any mutation.",
      "dependencies": ["ST-001"],
      "milestone": "M2",
      "worker_kind": "scout",
      "target_project": "firstmate",
      "capabilities": ["CAP-APPLY"]
    }
  ]
}
JSON
}

test_validate_and_render_linear_resident_spec() {
  local plan out
  plan="$TMP_ROOT/valid.json"
  write_valid_plan "$plan"

  out=$("$SHARD" validate "$plan") || fail "valid shard plan was rejected"
  assert_contains "$out" "valid" "validate did not report success"

  out=$("$SHARD" render-spec "$plan") || fail "render-spec failed"
  assert_contains "$out" "# Story sharder SPEC kernel" "rendered SPEC title missing"
  assert_contains "$out" "\`CAP-INTAKE\`" "rendered SPEC omitted capabilities"
  assert_contains "$out" "\`ST-002\` - Materialize approved stories" "rendered SPEC omitted story"
  assert_contains "$out" "Dependencies: \`ST-001\`" "rendered SPEC omitted dependency"
  assert_contains "$out" "Routine in-scope work outside this large-initiative shard continues" "autonomy clause missing"
  pass "valid shard plan validates and renders a Linear-resident SPEC proposal"
}

test_validate_rejects_private_or_missing_spec_surface() {
  local plan rc err
  plan="$TMP_ROOT/private-spec.json"
  write_valid_plan "$plan"
  python3 - "$plan" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
p["spec"]["linear"] = {"type": "private_file", "path": "data/fm-story-sharder/SPEC.md"}
json.dump(p, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PY
  set +e
  "$SHARD" validate "$plan" > "$TMP_ROOT/private.out" 2> "$TMP_ROOT/private.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "private SPEC placement was accepted"
  err=$(cat "$TMP_ROOT/private.err")
  assert_contains "$err" "spec.linear.type must be document or issue_description" "private SPEC rejection was not explicit"
  pass "shard validation rejects private SPEC placement"
}

test_apply_dry_run_preserves_dependencies_and_backlog_ids() {
  local plan out
  plan="$TMP_ROOT/dry-run.json"
  write_valid_plan "$plan"
  out=$("$SHARD" apply "$plan" --dry-run) || fail "apply --dry-run failed"
  python3 - <<'PY' "$out" || fail "dry-run output did not preserve materialization contract"
import json, sys
result = json.loads(sys.argv[1])
assert result["issues"]["ST-002"]["operation"] == "dry-run"
assert result["relations"] == [{"from": "ST-001", "to": "ST-002", "type": "blocks", "operation": "dry-run"}]
assert result["backlog"]["ST-001"]["id"] == "fm-story-sharder-schema"
assert result["backlog"]["ST-002"]["id"] == "fm-story-sharder-st-002"
assert result["backlog"]["ST-002"]["blocked_by"] == ["fm-story-sharder-schema"]
PY
  pass "apply dry-run exposes Linear dependency and backlog blocked-by plan"
}

test_propose_dry_run_requires_captain_decision_surface() {
  local plan out
  plan="$TMP_ROOT/propose.json"
  write_valid_plan "$plan"
  out=$("$SHARD" propose "$plan" --dry-run --captain-user-id captain-user-id) \
    || fail "propose --dry-run failed"
  assert_contains "$out" '"decision_issue"' "propose output omitted decision issue"
  assert_contains "$out" "Approval authorizes firstmate" "decision ticket body omitted approval authority"
  assert_contains "$out" "does not add an approval gate for routine in-scope work" "decision ticket body omitted autonomy guard"
  pass "propose dry-run creates a captain decision surface without touching Linear"
}

test_validate_and_render_linear_resident_spec
test_validate_rejects_private_or_missing_spec_surface
test_apply_dry_run_preserves_dependencies_and_backlog_ids
test_propose_dry_run_requires_captain_decision_surface
