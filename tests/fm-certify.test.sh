#!/usr/bin/env bash
# tests/fm-certify.test.sh - the certification predicate's contract: that
# CERTIFIED is computed rather than written, that it refuses on a dimension it
# could not observe and NAMES that dimension, and that a route which
# structurally cannot produce a piece of evidence reports not-applicable rather
# than being forced into a pass or a failure.
#
# The four values under test are deliberately not three. bin/fm-verify-lib.sh
# owns the three-valued OBSERVATION type and it is right at that level; a
# certification predicate additionally has to say "this route cannot produce
# this evidence at all", which is an applicability fact and not an observation.
# Collapsing that into could-not-observe is measurably what let honest per-pull-
# request disclosures collapse into one dishonest summary, so a case here holds
# them apart.
#
# Every case that asserts a refusal is paired with the positive form of the
# same fixture, so a refusal can never pass by accident of a broken fixture:
# an absence-based pass proves nothing until the same case has been seen green.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CERTIFY="$ROOT/bin/fm-certify.sh"

TMP_ROOT=$(fm_test_tmproot fm-certify-tests)

# A sandboxed home with a registry and a git repo whose landing route is known.
# <fork> yes gives origin a push url distinct from its fetch url, which is the
# fork-landing shape whose branch is deliberately unsigned.
make_case() {  # <name> [fork: yes|no] [declare-mapping: yes|no]
  local name=$1 fork=${2:-no} declare_map=${3:-yes} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/config" "$dir/state" "$dir/repo"
  fm_test_model_registry "$dir/config/models.json" "$declare_map"
  git -C "$dir/repo" init --quiet 2>/dev/null
  git -C "$dir/repo" remote add origin https://example.invalid/upstream.git
  if [ "$fork" = yes ]; then
    git -C "$dir/repo" remote set-url --push origin https://example.invalid/fork.git
  fi
  printf '%s\n' "$dir"
}

# Squeeze runs of whitespace so an assertion tests the CONTENT of a row rather
# than the column widths it happens to be padded to.
squeezed() { printf '%s' "$1" | tr -s ' '; }

certify() {  # <case_dir> [args...]
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$dir" FM_CONFIG_OVERRIDE="$dir/config" \
  FM_STATE_OVERRIDE="$dir/state" FM_PIPELINE_STATE_DB="$dir/pipeline.sqlite" \
    "$CERTIFY" "$@"
}

# --- the three observation values, each reachable ----------------------------

test_an_independent_checker_certifies() {
  local dir out rc
  # The fleet's real shape: a fork-landing route, where attestation is
  # deliberately not applicable, so independence is the applicable predicate.
  dir=$(make_case certified yes yes)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): an independent checker certifies"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 0 ] || fail "certified: an independent checker did not certify (rc=$rc):"$'\n'"$out"
  assert_contains "$out" "state=LANDED_AND_CERTIFIED" \
    "certified: the certified state was not reported"
  assert_contains "$(squeezed "$out")" "pool independent" \
    "certified: the pool dimension was not reported independent"
  pass "a checker independent on every dimension certifies, and says on which"
}

test_a_shared_pool_refuses_and_names_the_dimension() {
  local dir out rc
  dir=$(make_case shared-pool yes yes)
  # A different reviewing MODEL on the SAME credential pool. A single boolean
  # would call this independent.
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|anthropic|claude-fable-5" \
    || { pass "SKIP (python3 unavailable): a shared pool refuses"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 3 ] || fail "shared pool: expected an observed-unmet refusal (3), got $rc:"$'\n'"$out"
  assert_contains "$out" "state=LANDED_WITH_VERIFICATION_GAP" \
    "shared pool: the gap state was not reported"
  assert_contains "$out" "pool:not-independent" \
    "shared pool: the refusal did not NAME the pool dimension"
  # The distinction the four dimensions exist to preserve: this is not simply
  # "not independent", it is independent on model and not on pool.
  assert_contains "$(squeezed "$out")" "model independent" \
    "shared pool: an independent model was not reported as such"
  pass "a same-pool different-model checker refuses and names pool, not a bare verdict"
}

test_missing_verifier_identity_refuses_as_unobserved() {
  local dir out rc
  dir=$(make_case unobserved yes yes)
  # No pipeline record at all for these bytes: the identity was never captured.
  out=$(certify "$dir" --repo "$dir/repo" --branch fm/never-validated \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 4 ] || fail "unobserved: expected a could-not-observe refusal (4), got $rc:"$'\n'"$out"
  assert_contains "$out" "state=LANDED_WITH_VERIFICATION_GAP" \
    "unobserved: the gap state was not reported"
  assert_contains "$out" "could-not-observe" \
    "unobserved: the refusal did not report a could-not-observe"
  # It must never read as independent, and never as certified.
  case "$out" in
    *"state=LANDED_AND_CERTIFIED"*)
      fail "unobserved: an uncaptured verifier identity certified:"$'\n'"$out" ;;
  esac
  pass "a run whose verifier identity was never captured cannot certify"
}

test_undeclared_mapping_refuses_rather_than_inferring() {
  local dir out rc
  dir=$(make_case undeclared yes no)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): undeclared mapping refuses"; return; }

  # The reviewing vendor "openai" differs from the making vendor's name, and
  # the registry declares no mapping relating the two vocabularies. Differing
  # names are NOT evidence of two vendors.
  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 4 ] || fail "undeclared: expected a could-not-observe refusal (4), got $rc:"$'\n'"$out"
  assert_contains "$out" "vendor:could-not-observe" \
    "undeclared: the vendor dimension was not named as unobservable"
  case "$(squeezed "$out")" in
    *"vendor independent"*)
      fail "undeclared: independence was inferred from differing names:"$'\n'"$out" ;;
  esac
  pass "an undeclared vocabulary mapping refuses rather than inferring independence"
}

# --- the fourth, structural value --------------------------------------------

test_not_applicable_is_carried_with_its_route() {
  local dir out rc
  dir=$(make_case not-applicable yes yes)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): not-applicable carries its route"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?

  # A fork-landing branch is deliberately unsigned, so its missing attestation
  # is the route working as designed - not a gap in the evidence.
  assert_contains "$(squeezed "$out")" "attestation not-applicable" \
    "not-applicable: the deliberately unsigned route was not reported not-applicable"
  assert_contains "$out" "route=fork-landing" \
    "not-applicable: the value did not carry the route that caused it"

  # It must NOT be reported as could-not-observe: "this route cannot produce
  # this evidence" and "we could not look" need different repairs.
  case "$(squeezed "$out")" in
    *"attestation could-not-observe"*)
      fail "not-applicable: a structural non-applicability collapsed into could-not-observe:"$'\n'"$out" ;;
  esac
  # And it must not silently vanish into a pass either: the state line carries
  # it, so quoting the state word alone cannot overstate what was certified.
  [ "$rc" = 0 ] || fail "not-applicable: an otherwise-certifiable route did not certify (rc=$rc):"$'\n'"$out"
  assert_contains "$out" "not_applicable=attestation(fork-landing)" \
    "not-applicable: the state line did not carry what this route could not certify"
  pass "a route that structurally cannot produce evidence reports not-applicable with its route"
}

test_not_applicable_is_distinct_from_unobserved_on_the_same_predicate() {
  local fork direct fork_out direct_out
  fork=$(make_case na-fork yes yes)
  direct=$(make_case na-direct no yes)
  fm_test_pipeline_db "$fork/pipeline.sqlite" "$fork/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): not-applicable is distinct from unobserved"; return; }
  fm_test_pipeline_db "$direct/pipeline.sqlite" "$direct/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || fail "distinct: the direct-route fixture failed"

  fork_out=$(certify "$fork" --repo "$fork/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only || true)
  # The SAME predicate on a route that CAN be signed and simply was not read:
  # that is could-not-observe, and it must read differently from the fork case.
  direct_out=$(certify "$direct" --repo "$direct/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only || true)

  assert_contains "$(squeezed "$fork_out")" "attestation not-applicable" \
    "distinct: the fork route did not report not-applicable"
  case "$(squeezed "$direct_out")" in
    *"attestation not-applicable"*)
      fail "distinct: a signable route wrongly claimed not-applicable:"$'\n'"$direct_out" ;;
  esac
  assert_contains "$(squeezed "$direct_out")" "attestation could-not-observe" \
    "distinct: an unread attestation on a signable route was not could-not-observe"
  pass "not-applicable and could-not-observe stay apart on the same predicate"
}

test_no_argument_can_assert_a_certification_result() {
  local dir flag out
  dir=$(make_case unassertable no yes)
  # There must be no way to hand this command a verdict. Each of these would be
  # a writable escape hatch out of the predicate it exists to enforce.
  for flag in --certified --state --independence --independent --not-applicable \
      --skip-independence --assume-independent; do
    out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha "$flag" yes 2>&1) \
      && fail "unassertable: $flag was accepted, so certification is still writable"
    case "$out" in
      *"unknown option"*) ;;
      *) fail "unassertable: $flag was not refused as an unknown option: $out" ;;
    esac
  done
  pass "no argument can assert a certification result or waive a predicate"
}

test_historical_records_are_never_backfilled() {
  local dir out
  dir=$(make_case historical yes yes)
  # A branch the pipeline never recorded is exactly a historical run whose
  # verifier identity was never captured. It must stay could-not-observe rather
  # than acquiring a plausible identity, because a backfilled guess is
  # indistinguishable from a real observation afterwards.
  out=$(certify "$dir" --repo "$dir/repo" --branch fm/from-before \
    --maker-harness claude --maker-model opus --mode local-only || true)
  assert_contains "$out" "process:could-not-observe" \
    "historical: a run with no recorded identity did not stay could-not-observe"
  case "$out" in
    *"claude-opus-5"*|*"gpt-5.6-sol"*)
      fail "historical: an identity was invented for a run that recorded none:"$'\n'"$out" ;;
  esac
  pass "a run whose identity was never captured is never backfilled with a guess"
}

test_json_form_carries_every_dimension_and_the_route() {
  local dir out
  command -v jq >/dev/null 2>&1 || { pass "SKIP (jq unavailable): json form"; return; }
  dir=$(make_case json-form yes yes)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|anthropic|claude-fable-5" \
    || { pass "SKIP (python3 unavailable): json form"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only --json || true)
  printf '%s' "$out" | jq -e '.state == "LANDED_WITH_VERIFICATION_GAP"' >/dev/null \
    || fail "json: the state was not carried:"$'\n'"$out"
  printf '%s' "$out" | jq -e '[.independence[].dimension] == ["process","model","vendor","pool","overall"]' >/dev/null \
    || fail "json: not every dimension was reported:"$'\n'"$out"
  printf '%s' "$out" | jq -e '.not_applicable | index("attestation(fork-landing)")' >/dev/null \
    || fail "json: the not-applicable route was not carried:"$'\n'"$out"
  # Identity is carried per agent-backed STEP, not only per run, and the
  # reviewing purpose is distinguished from the agent that rewrites the code.
  printf '%s' "$out" | jq -e '[.steps[] | select(.purpose == "review")] | length >= 1' >/dev/null \
    || fail "json: no per-step reviewing identity was carried:"$'\n'"$out"
  # A non-reviewing step is carried as identity but must never be read as the
  # critic: the reviewing purpose alone decides who did the checking.
  printf '%s' "$out" | jq -e '[.steps[] | select(.purpose == "test")] | length >= 1' >/dev/null \
    || fail "json: a non-reviewing agent-backed step was dropped:"$'\n'"$out"
  printf '%s' "$out" | jq -e '[.independence[] | select(.reason | test("no-model"))] | length == 0' >/dev/null \
    || fail "json: a non-reviewing step was read as the critic:"$'\n'"$out"
  printf '%s' "$out" | jq -e '.steps[0] | has("vendor") and has("model") and has("exit_status")' >/dev/null \
    || fail "json: a step did not carry its invocation-time identity:"$'\n'"$out"
  pass "the machine form carries every dimension, the gap, the route, and per-step identity"
}

test_an_independent_checker_certifies
test_a_shared_pool_refuses_and_names_the_dimension
test_missing_verifier_identity_refuses_as_unobserved
test_undeclared_mapping_refuses_rather_than_inferring
test_not_applicable_is_carried_with_its_route
test_not_applicable_is_distinct_from_unobserved_on_the_same_predicate
test_no_argument_can_assert_a_certification_result
test_historical_records_are_never_backfilled
test_json_form_carries_every_dimension_and_the_route
