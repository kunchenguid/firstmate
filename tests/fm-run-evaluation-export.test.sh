#!/usr/bin/env bash
# Behavioral regression for the neutral, redacted Cockpit run-evaluation export.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-run-evaluation-export)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
DATA_DIR="$HOME_DIR/data"
FIXTURE="$ROOT/tests/fixtures/run-evaluation-v1/valid-partial-evaluation.json"
PUBLISHER="$ROOT/bin/fm-run-evaluation-export.sh"
OUTPUT="$STATE_DIR/cockpit-run-evaluation.json"
EXPECTED_VALIDATOR_SHA256=5f9ef989ed02260ff61328c7ca91f84529ab1a61f28abd01ba162780b6bbefc7
POLICY="$ROOT/bin/contracts/run-evaluation-v1/cockpit-redaction-policy-v1.json"

export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_DATA_OVERRIDE="$DATA_DIR"
mkdir -p "$STATE_DIR" "$DATA_DIR"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

surface_fixture() {
  cp "$FIXTURE" "$1"
}

fresh_source_dir() {
  local name=$1
  local directory="$TMP_ROOT/$name/data/run-evaluations"
  mkdir -p "$directory"
  printf '%s\n' "$directory"
}

run_export() {
  FM_DATA_OVERRIDE=$(dirname "$1") "$PUBLISHER"
}

VALID_DIR=$(fresh_source_dir valid)
surface_fixture "$VALID_DIR/evaluation.json"
VALID_DIGEST=$(sha256_file "$VALID_DIR/evaluation.json")
OUT=$(run_export "$VALID_DIR") || fail "valid run-evaluation publication failed"
assert_contains "$OUT" "published 1 run-evaluation record(s); withheld 0" "valid publication did not report its bounded outcome"
jq -e --arg digest "sha256:$VALID_DIGEST" '
  .schemaVersion == "governance.cockpit-run-evaluation-export.v1"
  and .kind == "cockpit_run_evaluation_export"
  and .freshness == {staleAfterSeconds:300}
  and .retention == {mode:"rolling_snapshot",maxRecords:100,maxBytes:262144}
  and (.records | length) == 1
  and .records[0].sourceEvaluationDigest == $digest
  and .records[0].subject.route == {routeRef:"route.synthetic.readonly"}
  and .records[0].scoringProfile
    == {
      id:"golden-tasks.synthetic",
      version:1,
      digest:"sha256:a982818f4f82e805bc85dfab28b3baa31704bc17297870018f19c526c7e80c7f"
    }
  and .records[0].dimensions.reviewEffort.raw.value == null
  and .records[0].dimensions.reviewEffort.normalized == null
  and .records[0].comparisons.model.candidateKey == .records[0].identityKeys.modelKey
  and .records[0].comparisons.executionHarness.candidateKey
    == .records[0].identityKeys.executionHarnessKey
  and .records[0].comparisons.fullRoute.candidateKey
    == .records[0].identityKeys.fullRouteKey
  and .withheld == {count:0,reasonCounts:[]}
' "$OUTPUT" >/dev/null || fail "valid publication did not preserve the neutral consumer contract"
if jq -e '
    .. | objects
    | has("overallScore")
      or has("rank")
      or has("weightedScore")
      or has("routingRecommendation")
      or has("routingPolicyVersion")
      or has("permissionProfileRef")
      or has("dispatcherAdapter")
  ' "$OUTPUT" >/dev/null; then
  fail "consumer projection leaked scoring, routing, or unredacted route fields"
fi
pass "valid input publishes one bounded projection with separate comparison identities"

ACTUAL_VALIDATOR_SHA256=$(sha256_file "$ROOT/bin/contracts/run-evaluation-v1/validate_run_evaluation.py")
assert_equals "$EXPECTED_VALIDATOR_SHA256" "$ACTUAL_VALIDATOR_SHA256" "vendored governance validator drifted from its pinned source digest"
jq -e '
  .id == "firstmate.cockpit-surface-labelled"
  and .version == 1
  and .sourceContract == "governance.run-evaluation.v1"
  and .consumerContract == "governance.cockpit-run-evaluation-export.v1"
  and .validatorOrigin == {
    repository:"00_Architektur",
    branch:"codex/run-evaluation-contract-v1",
    commit:"b5f4104f93d075cd9140c4dcb6cf06fbeb1501ac",
    path:"scripts/validate_run_evaluation.py",
    sha256:"5f9ef989ed02260ff61328c7ca91f84529ab1a61f28abd01ba162780b6bbefc7",
    canonicalMainAtCopy:false
  }
  and .allowedDataClasses == ["synthetic","public","internal_non_sensitive"]
  and .allowedEvidenceVisibility == "surface_labelled"
  and .withheldReasonCodes == [
    "byte_limit",
    "classification_blocked",
    "duplicate_source",
    "evaluation_identity_conflict",
    "record_limit",
    "redaction_blocked",
    "revision_conflict",
    "revision_superseded",
    "source_invalid",
    "source_read_failed",
    "source_symlink_blocked"
  ]
  and .projectionOnly == true
' "$POLICY" >/dev/null || fail "redaction policy drifted from the accepted consumer boundary"
[ ! -e "$ROOT/bin/contracts/run-evaluation-v1/__pycache__" ] || fail "loading the vendored validator wrote bytecode into the tracked code root"
pass "consumer validation remains byte-bound to the accepted governance validator"

HOME_ONLY_DIR=$(fresh_source_dir home-only)
jq '(.dimensions[] | .evidenceRefs[]? | .visibility) = "home_only"' "$FIXTURE" > "$HOME_ONLY_DIR/evaluation.json"
run_export "$HOME_ONLY_DIR" >/dev/null || fail "home-only evidence should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.count == 1
  and .withheld.reasonCounts == [{code:"redaction_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "home-only evidence was not withheld at the redaction boundary"
pass "non-surface evidence is withheld rather than promoted or stripped"

SENSITIVE_DIR=$(fresh_source_dir sensitive)
surface_fixture "$SENSITIVE_DIR/evaluation.json"
jq '.dataClass = "sensitive"' "$SENSITIVE_DIR/evaluation.json" > "$SENSITIVE_DIR/evaluation.next"
mv "$SENSITIVE_DIR/evaluation.next" "$SENSITIVE_DIR/evaluation.json"
run_export "$SENSITIVE_DIR" >/dev/null || fail "sensitive input should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"classification_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "sensitive input crossed the Cockpit data-class boundary"
pass "sensitive and production classes remain outside the Cockpit snapshot"

UNDERCLASSIFIED_DIR=$(fresh_source_dir underclassified)
surface_fixture "$UNDERCLASSIFIED_DIR/evaluation.json"
jq '.derivedFrom.agentRunRecord.dataClass = "sensitive"' "$UNDERCLASSIFIED_DIR/evaluation.json" > "$UNDERCLASSIFIED_DIR/evaluation.next"
mv "$UNDERCLASSIFIED_DIR/evaluation.next" "$UNDERCLASSIFIED_DIR/evaluation.json"
run_export "$UNDERCLASSIFIED_DIR" >/dev/null || fail "underclassified input should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"classification_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "underclassified input did not report its safety reason"
pass "underclassified evaluation input is withheld"

EVIDENCE_CLASS_DIR=$(fresh_source_dir evidence-class)
surface_fixture "$EVIDENCE_CLASS_DIR/evaluation.json"
jq '.dimensions.quality.evidenceRefs[0].dataClass = "sensitive"' "$EVIDENCE_CLASS_DIR/evaluation.json" > "$EVIDENCE_CLASS_DIR/evaluation.next"
mv "$EVIDENCE_CLASS_DIR/evaluation.next" "$EVIDENCE_CLASS_DIR/evaluation.json"
run_export "$EVIDENCE_CLASS_DIR" >/dev/null || fail "overclassified evidence should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"classification_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "overclassified evidence did not report its classification reason"
pass "evidence above the evaluation class is reported as a classification block"

CREDENTIAL_DIR=$(fresh_source_dir credential)
surface_fixture "$CREDENTIAL_DIR/evaluation.json"
jq '.subject.model.modelId = "token_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"' "$CREDENTIAL_DIR/evaluation.json" > "$CREDENTIAL_DIR/evaluation.next"
mv "$CREDENTIAL_DIR/evaluation.next" "$CREDENTIAL_DIR/evaluation.json"
run_export "$CREDENTIAL_DIR" >/dev/null || fail "credential-shaped input should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"redaction_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "credential-shaped input did not stop at the redaction boundary"
assert_no_grep "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890" "$OUTPUT" "credential-shaped input leaked into the Cockpit snapshot"
pass "credential-shaped values are withheld without being copied"

PROVIDER_CREDENTIAL_DIR=$(fresh_source_dir provider-credential)
surface_fixture "$PROVIDER_CREDENTIAL_DIR/evaluation.json"
jq '.dimensions.reviewEffort.reasonCodes = ["ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"]' "$PROVIDER_CREDENTIAL_DIR/evaluation.json" > "$PROVIDER_CREDENTIAL_DIR/evaluation.next"
mv "$PROVIDER_CREDENTIAL_DIR/evaluation.next" "$PROVIDER_CREDENTIAL_DIR/evaluation.json"
run_export "$PROVIDER_CREDENTIAL_DIR" >/dev/null || fail "provider credential-shaped input should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"redaction_blocked",count:1}]
' "$OUTPUT" >/dev/null || fail "provider credential-shaped input did not stop at the redaction boundary"
assert_no_grep "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890" "$OUTPUT" "provider credential-shaped input leaked into the Cockpit snapshot"
pass "standalone provider credentials are withheld before projection"

PRIVATE_DIR=$(fresh_source_dir private-content)
surface_fixture "$PRIVATE_DIR/private-path.json"
jq '.subject.route.routeRef = "C:/Users/chris/private"' "$PRIVATE_DIR/private-path.json" > "$PRIVATE_DIR/private-path.next"
mv "$PRIVATE_DIR/private-path.next" "$PRIVATE_DIR/private-path.json"
surface_fixture "$PRIVATE_DIR/free-text.json"
jq '.prompt = "copy this private transcript"' "$PRIVATE_DIR/free-text.json" > "$PRIVATE_DIR/free-text.next"
mv "$PRIVATE_DIR/free-text.next" "$PRIVATE_DIR/free-text.json"
run_export "$PRIVATE_DIR" >/dev/null || fail "private-path and free-text sources should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.count == 2
  and .withheld.reasonCounts == [{code:"source_invalid",count:2}]
' "$OUTPUT" >/dev/null || fail "private-path or free-text input crossed the exact schema boundary"
assert_no_grep "Users/chris" "$OUTPUT" "a private path leaked into the Cockpit snapshot"
assert_no_grep "private transcript" "$OUTPUT" "free text leaked into the Cockpit snapshot"
pass "private paths, prompts, transcripts, and other free text cannot enter the projection"

MALFORMED_DIR=$(fresh_source_dir malformed)
printf '{"kind":"run_evaluation","kind":"duplicate"}\n' > "$MALFORMED_DIR/duplicate.json"
printf '{"truncated":\n' > "$MALFORMED_DIR/truncated.json"
printf '\377\n' > "$MALFORMED_DIR/invalid-utf8.json"
printf '{"kind":"run_evaluation","dataClass":[]}\n' > "$MALFORMED_DIR/array-class.json"
printf '{"kind":"run_evaluation","dataClass":"unknown"}\n' > "$MALFORMED_DIR/unknown-class.json"
printf '{"kind":"run_evaluation"}\n' > "$MALFORMED_DIR/missing-class.json"
mkdir "$MALFORMED_DIR/not-regular.json"
run_export "$MALFORMED_DIR" >/dev/null || fail "malformed sources should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.count == 7
  and .withheld.reasonCounts == [
    {code:"source_invalid",count:6},
    {code:"source_read_failed",count:1}
  ]
' "$OUTPUT" >/dev/null || fail "invalid content and source read failures were not classified separately"
pass "malformed content is isolated and distinguished from read failures"

SYMLINK_SOURCE_DIR=$(fresh_source_dir linked-source)
if ln -s "$VALID_DIR/evaluation.json" "$SYMLINK_SOURCE_DIR/evaluation.json" 2>/dev/null && [ -L "$SYMLINK_SOURCE_DIR/evaluation.json" ]; then
  run_export "$SYMLINK_SOURCE_DIR" >/dev/null || fail "linked source should be withheld without failing publication"
  jq -e '
    (.records | length) == 0
    and .withheld.reasonCounts == [{code:"source_symlink_blocked",count:1}]
  ' "$OUTPUT" >/dev/null || fail "linked source was followed"
  pass "source symlinks are never followed"
else
  rm -f "$SYMLINK_SOURCE_DIR/evaluation.json"
  pass "source symlink check is unavailable on this filesystem"
fi

REVISION_DIR=$(fresh_source_dir revisions)
surface_fixture "$REVISION_DIR/revision-2.json"
jq '
  .evaluationId = "evaluation.synthetic.001.r1"
  | .derivedFrom.agentRunRecord.revision = 1
  | .freshness.sourceRevision = 1
' "$REVISION_DIR/revision-2.json" > "$REVISION_DIR/revision-1.json"
run_export "$REVISION_DIR" >/dev/null || fail "revision selection failed"
jq -e '
  (.records | length) == 1
  and .records[0].sourceEvaluationId == "evaluation.synthetic.001"
  and .withheld.reasonCounts == [{code:"revision_superseded",count:1}]
' "$OUTPUT" >/dev/null || fail "newest source revision did not replace its older immutable evaluation"
pass "newest source revision wins without mutating append-only inputs"

BLOCKED_REVISION_DIR=$(fresh_source_dir blocked-revision)
surface_fixture "$BLOCKED_REVISION_DIR/revision-2.json"
jq '(.dimensions[] | .evidenceRefs[]? | .visibility) = "home_only"' "$BLOCKED_REVISION_DIR/revision-2.json" > "$BLOCKED_REVISION_DIR/revision-2.next"
mv "$BLOCKED_REVISION_DIR/revision-2.next" "$BLOCKED_REVISION_DIR/revision-2.json"
jq '
  .evaluationId = "evaluation.synthetic.blocked-revision.r1"
  | .derivedFrom.agentRunRecord.revision = 1
  | .freshness.sourceRevision = 1
  | (.dimensions[] | .evidenceRefs[]? | .visibility) = "surface_labelled"
' "$BLOCKED_REVISION_DIR/revision-2.json" > "$BLOCKED_REVISION_DIR/revision-1.json"
run_export "$BLOCKED_REVISION_DIR" >/dev/null || fail "blocked newest revision should produce a safe empty publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [
    {code:"redaction_blocked",count:1},
    {code:"revision_superseded",count:1}
  ]
' "$OUTPUT" >/dev/null || fail "an older exportable revision replaced a newer redaction-blocked revision"
pass "newest validated revision controls export eligibility"

DUPLICATE_DIR=$(fresh_source_dir duplicate)
surface_fixture "$DUPLICATE_DIR/one.json"
cp "$DUPLICATE_DIR/one.json" "$DUPLICATE_DIR/two.json"
run_export "$DUPLICATE_DIR" >/dev/null || fail "byte-identical duplicate selection failed"
jq -e '
  (.records | length) == 1
  and .withheld.reasonCounts == [{code:"duplicate_source",count:1}]
' "$OUTPUT" >/dev/null || fail "byte-identical duplicate sources produced duplicate records"
pass "duplicate immutable sources collapse to one exported record"

LIMIT_DIR=$(fresh_source_dir limits)
i=1
while [ "$i" -le 101 ]; do
  surface_fixture "$LIMIT_DIR/evaluation-$i.json"
  jq --arg suffix "$i" '
    .evaluationId = ("evaluation.synthetic." + $suffix)
    | .derivedFrom.agentRunRecord.runId = ("run.synthetic." + $suffix)
  ' "$LIMIT_DIR/evaluation-$i.json" > "$LIMIT_DIR/evaluation-$i.next"
  mv "$LIMIT_DIR/evaluation-$i.next" "$LIMIT_DIR/evaluation-$i.json"
  i=$((i + 1))
done
run_export "$LIMIT_DIR" >/dev/null || fail "bounded rolling snapshot publication failed"
BYTES=$(LC_ALL=C wc -c < "$OUTPUT" | tr -d ' ')
jq -e '
  (.records | length) <= 100
  and ([.withheld.reasonCounts[] | select(.code == "record_limit" and .count == 1)] | length) == 1
  and ([.withheld.reasonCounts[] | select(.code == "byte_limit" and .count > 0)] | length) == 1
' "$OUTPUT" >/dev/null || fail "record-count overflow was not withheld"
[ "$BYTES" -le 262144 ] || fail "published snapshot exceeded 262144 UTF-8 bytes"
pass "rolling snapshot enforces both record-count and UTF-8 byte limits"

CONFLICT_DIR=$(fresh_source_dir conflict)
surface_fixture "$CONFLICT_DIR/one.json"
jq '.evaluationId = "evaluation.synthetic.conflict"' "$CONFLICT_DIR/one.json" > "$CONFLICT_DIR/two.json"
run_export "$CONFLICT_DIR" >/dev/null || fail "same-revision conflict should produce a safe empty publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"revision_conflict",count:2}]
' "$OUTPUT" >/dev/null || fail "same-run same-revision conflict was selected arbitrarily"
pass "conflicting evaluations for one run revision are withheld together"

IDENTITY_CONFLICT_DIR=$(fresh_source_dir identity-conflict)
surface_fixture "$IDENTITY_CONFLICT_DIR/one.json"
jq '.derivedFrom.agentRunRecord.runId = "run.synthetic.identity-conflict"' "$IDENTITY_CONFLICT_DIR/one.json" > "$IDENTITY_CONFLICT_DIR/two.json"
run_export "$IDENTITY_CONFLICT_DIR" >/dev/null || fail "evaluation-identity conflict should produce a safe empty publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"evaluation_identity_conflict",count:2}]
' "$OUTPUT" >/dev/null || fail "one evaluation identity was allowed to describe multiple runs"
pass "conflicting run bindings for one evaluation identity are withheld together"

CROSS_REVISION_IDENTITY_DIR=$(fresh_source_dir cross-revision-identity)
surface_fixture "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.json"
jq '.evaluationId = "evaluation.synthetic.current"' "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.json" > "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.next"
mv "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.next" "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.json"
jq '
  .evaluationId = "evaluation.synthetic.shared"
  | .derivedFrom.agentRunRecord.revision = 1
  | .freshness.sourceRevision = 1
' "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-2.json" > "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-1.json"
jq '.derivedFrom.agentRunRecord.runId = "run.synthetic.other"' "$CROSS_REVISION_IDENTITY_DIR/run-a-revision-1.json" > "$CROSS_REVISION_IDENTITY_DIR/run-b-revision-1.json"
run_export "$CROSS_REVISION_IDENTITY_DIR" >/dev/null || fail "cross-revision identity conflict should not abort publication"
jq -e '
  (.records | length) == 1
  and .records[0].sourceEvaluationId == "evaluation.synthetic.current"
  and .withheld.reasonCounts == [{code:"evaluation_identity_conflict",count:2}]
' "$OUTPUT" >/dev/null || fail "a superseded evaluation identity conflict crossed run boundaries"
pass "evaluation identity conflicts are detected before revision selection"

INVALID_STATE_DIR=$(fresh_source_dir invalid-state)
surface_fixture "$INVALID_STATE_DIR/evaluation.json"
jq '
  .state = {status:"invalid",reasonCodes:["source_invalid"]}
  | (.comparisons[] |= {
      eligibility:"ineligible",
      candidateKey:null,
      cohortKey:null,
      reasonCodes:["source_invalid"]
    })
' "$INVALID_STATE_DIR/evaluation.json" > "$INVALID_STATE_DIR/evaluation.next"
mv "$INVALID_STATE_DIR/evaluation.next" "$INVALID_STATE_DIR/evaluation.json"
run_export "$INVALID_STATE_DIR" >/dev/null || fail "invalid evaluation state should be withheld without failing publication"
jq -e '
  (.records | length) == 0
  and .withheld.reasonCounts == [{code:"source_invalid",count:1}]
' "$OUTPUT" >/dev/null || fail "invalid evaluation state entered the consumer snapshot"
pass "contract-valid invalid evaluations remain unexportable"

EMPTY_DIR=$(fresh_source_dir empty)
run_export "$EMPTY_DIR" >/dev/null || fail "empty source directory should publish an empty snapshot"
jq -e '
  (.records | length) == 0
  and .withheld == {count:0,reasonCounts:[]}
' "$OUTPUT" >/dev/null || fail "empty source directory did not produce the canonical empty snapshot"
if find "$STATE_DIR" -maxdepth 1 -name '.cockpit-run-evaluation.json.*' -print -quit | grep -q .; then
  fail "atomic publication left a temporary file behind"
fi
pass "empty input is explicit and atomic publication leaves no partial file"

TAMPER_CODE="$TMP_ROOT/tampered-code/bin"
mkdir -p "$TAMPER_CODE/contracts/run-evaluation-v1"
cp "$ROOT/bin/fm-run-evaluation-export.sh" "$TAMPER_CODE/"
cp "$ROOT/bin/fm-run-evaluation-export.py" "$TAMPER_CODE/"
cp "$ROOT/bin/contracts/run-evaluation-v1/validate_run_evaluation.py" "$TAMPER_CODE/contracts/run-evaluation-v1/"
cp "$POLICY" "$TAMPER_CODE/contracts/run-evaluation-v1/"
printf '\n# tampered\n' >> "$TAMPER_CODE/contracts/run-evaluation-v1/validate_run_evaluation.py"
cp "$OUTPUT" "$STATE_DIR/pre-tamper-snapshot.json"
if FM_DATA_OVERRIDE=$(dirname "$VALID_DIR") bash "$TAMPER_CODE/fm-run-evaluation-export.sh" >/dev/null 2>&1; then
  fail "publisher accepted a validator that did not match the pinned digest"
fi
cmp -s "$OUTPUT" "$STATE_DIR/pre-tamper-snapshot.json" || fail "validator-integrity refusal changed the prior snapshot"
pass "validator-integrity failure preserves the prior complete snapshot"

cp "$ROOT/bin/contracts/run-evaluation-v1/validate_run_evaluation.py" "$TAMPER_CODE/contracts/run-evaluation-v1/"
jq '.projectionOnly = false' "$POLICY" > "$TAMPER_CODE/contracts/run-evaluation-v1/cockpit-redaction-policy-v1.json"
if FM_DATA_OVERRIDE=$(dirname "$VALID_DIR") bash "$TAMPER_CODE/fm-run-evaluation-export.sh" >/dev/null 2>&1; then
  fail "publisher accepted a weakened redaction policy"
fi
cmp -s "$OUTPUT" "$STATE_DIR/pre-tamper-snapshot.json" || fail "policy-integrity refusal changed the prior snapshot"
pass "redaction-policy weakening preserves the prior complete snapshot"

cp "$OUTPUT" "$STATE_DIR/prior-snapshot.json"
printf 'sentinel\n' > "$STATE_DIR/sentinel"
rm "$OUTPUT"
if ln -s "$STATE_DIR/sentinel" "$OUTPUT" 2>/dev/null && [ -L "$OUTPUT" ]; then
  if run_export "$EMPTY_DIR" >/dev/null 2>&1; then
    fail "publication followed or replaced an existing destination symlink"
  fi
  assert_grep "sentinel" "$STATE_DIR/sentinel" "destination symlink refusal changed its target"
  [ -L "$OUTPUT" ] || fail "destination symlink refusal replaced the linked path"
  rm "$OUTPUT"
  mv "$STATE_DIR/prior-snapshot.json" "$OUTPUT"
  pass "unsafe destination types are refused without touching their target"
else
  rm -f "$OUTPUT"
  mv "$STATE_DIR/prior-snapshot.json" "$OUTPUT"
  pass "destination symlink check is unavailable on this filesystem"
fi

cp "$OUTPUT" "$STATE_DIR/pre-fixed-path-snapshot.json"
if "$PUBLISHER" --source-dir "$VALID_DIR" >/dev/null 2>&1; then
  fail "publisher retained an arbitrary source-directory option"
fi
cmp -s "$OUTPUT" "$STATE_DIR/pre-fixed-path-snapshot.json" || fail "unsupported source option changed the prior snapshot"
pass "publication accepts only the fixed home data path"

MISSING_DATA_DIR="$TMP_ROOT/missing-source/data"
cp "$OUTPUT" "$STATE_DIR/pre-missing-source-snapshot.json"
if FM_DATA_OVERRIDE="$MISSING_DATA_DIR" "$PUBLISHER" >/dev/null 2>&1; then
  fail "publisher replaced the prior snapshot when its fixed source directory was missing"
fi
cmp -s "$OUTPUT" "$STATE_DIR/pre-missing-source-snapshot.json" || fail "missing fixed source directory changed the prior snapshot"
pass "missing fixed source directory preserves the prior snapshot"

HOME_SOURCE_DIR="$DATA_DIR/run-evaluations"
mkdir -p "$HOME_SOURCE_DIR"
surface_fixture "$HOME_SOURCE_DIR/evaluation.json"
EMPTY_OVERRIDE_CWD="$TMP_ROOT/empty-overrides-cwd"
mkdir -p "$EMPTY_OVERRIDE_CWD"
rm -f "$OUTPUT" "$EMPTY_OVERRIDE_CWD/cockpit-run-evaluation.json"
OUT=$(
  cd "$EMPTY_OVERRIDE_CWD" || exit 1
  FM_ROOT_OVERRIDE='' FM_DATA_OVERRIDE='' FM_STATE_OVERRIDE='' "$PUBLISHER"
) || fail "empty path overrides should fall back to the effective home"
assert_contains "$OUT" "published 1 run-evaluation record(s); withheld 0" "empty path overrides did not use the effective home"
jq -e '(.records | length) == 1' "$OUTPUT" >/dev/null || fail "empty path overrides did not publish beneath the effective home"
[ ! -e "$EMPTY_OVERRIDE_CWD/cockpit-run-evaluation.json" ] || fail "empty state override published into the current directory"
pass "empty path overrides use established home fallbacks"
