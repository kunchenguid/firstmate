#!/usr/bin/env bash
# Focused behavior tests for the SpecGraph v0.1 schema, conservative evidence
# levels, incomplete records, idempotent publication, and fail-open hook adapter.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$ROOT/bin/fm-specgraph-capture.sh"
LIB="$ROOT/bin/fm-specgraph-lib.sh"
SCHEMA="$ROOT/docs/specgraph-snapshot-v0.1.schema.json"
TMP_ROOT=$(fm_test_tmproot fm-specgraph-capture)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/sample-task" "$home/state"
  printf '# Sample report\n\nFiled synthetic evidence.\n' > "$home/data/sample-task/report.md"
  fm_write_meta "$home/state/sample-task.meta" \
    'window=firstmate:fm-sample-task' \
    'harness=codex' \
    'model=gpt-test' \
    'effort=high' \
    'kind=ship'
  printf '%s\n' "$home"
}

run_capture() {
  local home=$1
  shift
  FM_HOME="$home" "$CAPTURE" capture "$@"
}

test_schema_and_idempotent_publication() {
  local home snapshot repeated count
  home=$(make_home schema)
  snapshot=$(run_capture "$home" \
    --event task-completed --subject sample-task \
    --source "$home/state/sample-task.meta" \
    --source "$home/data/sample-task/report.md" \
    --inference 'a possible interpretation that still needs adoption') \
    || fail "capture failed"
  "$CAPTURE" validate "$snapshot" >/dev/null || fail "generated snapshot failed public validation"
  jq -e '
    .schemaVersion == "specgraph.snapshot.v0.1"
    and .sequence == 1
    and .status == "INCOMPLETE"
    and .authorityCompleteness == "PARTIAL"
    and .actor.kind == "model"
    and .actor.harness == "codex"
    and .actor.model == "gpt-test"
    and .actor.effort == "high"
    and ([.nodes[].type] | index("Snapshot") != null)
    and ([.nodes[].type] | index("Task") != null)
    and ([.nodes[].type] | index("Artifact") != null)
    and ([.nodes[].type] | index("Evidence") != null)
    and (.nodes | all(.[]; (.epistemic.sourceRefs | length) > 0))
    and (.edges | all(.[]; (.epistemic.sourceRefs | length) > 0))
  ' "$snapshot" >/dev/null || fail "snapshot contract fields were incomplete"
  [ "$(file_mode "$home/data/specgraph")" = 700 ] || fail "snapshot directory was not private"
  [ "$(file_mode "$snapshot")" = 600 ] || fail "snapshot file was not private"

  repeated=$(run_capture "$home" \
    --event task-completed --subject sample-task \
    --source "$home/state/sample-task.meta" \
    --source "$home/data/sample-task/report.md" \
    --inference 'a possible interpretation that still needs adoption') \
    || fail "idempotent capture retry failed"
  [ "$snapshot" = "$repeated" ] || fail "identical capture allocated a different snapshot"
  count=$(find "$home/data/specgraph" -maxdepth 1 -type f -name '*.json' | wc -l | tr -d ' ')
  [ "$count" -eq 1 ] || fail "identical capture produced duplicate files"
  pass "SpecGraph snapshots validate, stay private, and publish idempotently"
}

test_inference_is_not_promoted() {
  local home snapshot
  home=$(make_home inference)
  snapshot=$(run_capture "$home" \
    --event task-completed --subject sample-task \
    --source "$home/data/sample-task/report.md" \
    --inference 'supporting bytes do not make this semantic guess authoritative') \
    || fail "inference capture failed"
  jq -e '
    [.nodes[] | select(.properties.predicate? == "inferred-observation")]
      | length == 1
        and .[0].epistemic.level == "INFERRED"
        and .[0].authority == "ADVISORY"
        and .[0].properties.adoptionRequired == true
  ' "$snapshot" >/dev/null || fail "inference was absent or promoted"
  jq -e '
    [.edges[] | select(.to | startswith("claim:inferred:"))]
      | length == 1 and .[0].epistemic.level == "INFERRED"
  ' "$snapshot" >/dev/null || fail "inferred edge was promoted"
  pass "filed supporting bytes never auto-promote INFERRED nodes or edges"
}

test_incomplete_record_for_missing_material() {
  local home snapshot
  home=$(make_home incomplete)
  snapshot=$(run_capture "$home" \
    --event task-completed --subject missing-material \
    --source "$home/data/missing-report.md") \
    || fail "missing material did not produce an incomplete record"
  "$CAPTURE" validate "$snapshot" >/dev/null || fail "incomplete record was not schema-valid"
  jq -e '
    .status == "INCOMPLETE"
    and .authorityCompleteness == "UNKNOWN"
    and (.incompleteReasons | any(contains("missing, unreadable, or a symlink")))
    and (.trigger.sourceRefs | any(.kind == "absence" and .sha256 == null))
    and (.nodes | any(.epistemic.level == "UNKNOWN"))
  ' "$snapshot" >/dev/null || fail "missing material was hidden or invented"
  pass "missing material produces an explicit UNKNOWN incomplete snapshot"
}

test_validator_rejects_invalid_evidence_level() {
  local home snapshot invalid rc
  home=$(make_home invalid)
  snapshot=$(run_capture "$home" \
    --event task-completed --subject sample-task \
    --source "$home/data/sample-task/report.md") \
    || fail "valid fixture capture failed"
  invalid="$home/invalid.json"
  jq '.nodes[0].epistemic.level = "ASSERTED"' "$snapshot" > "$invalid"
  set +e
  "$CAPTURE" validate "$invalid" > "$home/invalid.out" 2> "$home/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "validator accepted an evidence level outside the three-part enum"
  pass "validator rejects snapshots outside the three-part evidence contract"
}

test_capture_failure_is_fail_open_and_logged() {
  local home fake rc=0
  home=$(make_home fail-open)
  fake="$home/failing-capture"
  printf '#!/usr/bin/env bash\nexit 19\n' > "$fake"
  chmod +x "$fake"
  # shellcheck source=/dev/null
  . "$LIB"
  FM_SPECGRAPH_CAPTURE_BIN="$fake" fm_specgraph_capture_best_effort "$home/state" \
    --event task-completed --subject sample-task --source "$home/data/sample-task/report.md" \
    > "$home/fail-open.out" 2> "$home/fail-open.err" || rc=$?
  [ "$rc" -eq 0 ] || fail "capture failure changed the caller exit status"
  assert_grep 'event=task-completed' "$home/state/specgraph-capture.failures.log" \
    "capture failure was not recorded"
  assert_grep 'subject=sample-task' "$home/state/specgraph-capture.failures.log" \
    "capture failure log lost the subject"
  assert_grep 'primary flow is continuing' "$home/fail-open.err" \
    "fail-open warning was not explicit"
  pass "capture failure is logged without blocking the primary flow"
}

jq -e '
  .properties.schemaVersion.const == "specgraph.snapshot.v0.1"
  and ([.["$defs"].node.properties.type.enum[]] | contains([
    "Goal", "Decision", "Spec", "Component", "WorkflowMap", "Task", "Artifact",
    "Evidence", "Assumption", "Claim", "ReviewAssertion", "Capability", "Gate",
    "Gap", "Snapshot"
  ]))
  and ([.["$defs"].edge.properties.predicate.enum[]] | contains([
    "defines", "supersedes", "blocked_by", "blocks", "belongs_to", "supports",
    "refutes", "reviews", "challenges", "validates", "adopts", "rejects",
    "invalidates", "governs", "guards", "derived_from", "valid_in"
  ]))
  and (.["$defs"].edge.required | contains(["scope", "supersession"]))
  and (.["$defs"].supersession.properties.mode.enum == ["full", "partial"])
' "$SCHEMA" >/dev/null || fail "canonical JSON Schema vocabulary or supersession contract is incomplete"
test_schema_and_idempotent_publication
test_inference_is_not_promoted
test_incomplete_record_for_missing_material
test_validator_rejects_invalid_evidence_level
test_capture_failure_is_fail_open_and_logged
