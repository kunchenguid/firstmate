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
  FM_CERTIFY_ATTEST="${FM_CERTIFY_ATTEST:-}" \
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

test_a_review_with_no_recorded_session_is_could_not_observe() {
  local dir out rc
  dir=$(make_case unsessioned yes yes)
  # The reviewing invocation IS recorded; only its session rows are absent. That
  # is the case the process dimension exists to hold apart: "a review ran" and
  # "the review ran in a process of its own" are different facts, and an empty
  # reviewer/review-fixer overlap on a run that recorded no session at all is an
  # absence of evidence rather than evidence of separation.
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol||none" \
    || { pass "SKIP (python3 unavailable): an unrecorded session is could-not-observe"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 4 ] || fail "unsessioned: expected a could-not-observe refusal (4), got $rc:"$'\n'"$out"
  assert_contains "$out" "process:could-not-observe" \
    "unsessioned: a review with no recorded session was not could-not-observe"
  case "$(squeezed "$out")" in
    *"process independent"*)
      fail "unsessioned: a session that was never recorded read as independent:"$'\n'"$out" ;;
  esac
  # The other dimensions resolving is what proves this case did NOT arrive at
  # its answer through the earlier "no agent invocation for these bytes" branch.
  # Without this, the same assertion would pass against an unconditional PASS.
  assert_contains "$(squeezed "$out")" "model independent" \
    "unsessioned: the reviewing invocation was not read, so the case proves nothing"
  pass "a recorded review whose session was never captured is could-not-observe, not independent"
}

test_one_unobserved_run_is_not_masked_by_a_sibling_that_recorded_one() {
  local dir out rc
  dir=$(make_case unsessioned-sibling yes yes)
  # Two runs on ONE branch: the first recorded its sessions, the second did not.
  # Independence is a property of a run against specific bytes, so the branch
  # reports its WEAKEST run - summing the evidence would answer a different
  # question, and answer it reassuringly.
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" \
    "fm/alpha|openai|gpt-5.6-sol" "fm/alpha|openai|gpt-5.6-sol||none" \
    || { pass "SKIP (python3 unavailable): an unobserved run is not masked"; return; }

  out=$(certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 4 ] || fail "sibling: a masked unobserved run certified (rc=$rc):"$'\n'"$out"
  assert_contains "$out" "process:could-not-observe" \
    "sibling: a run with no recorded session was masked by one that had them"
  pass "a run whose session was never recorded is not masked by a sibling run that recorded one"
}

test_an_absent_reviewing_identity_never_becomes_evidence() {
  local sessioned unsessioned out
  # A reviewing invocation the pipeline recorded with NEITHER a provider NOR a
  # model. Both identity fields are empty, and everything the run is judged on
  # is carried in the fields AFTER them, so a separator that swallows an empty
  # field would slide the session counts across and read a review count as a
  # shared session. An absence of evidence must never become evidence, and least
  # of all evidence of DEPENDENCE - the one value the folds above let survive
  # everything downstream.
  sessioned=$(make_case absent-identity yes yes)
  fm_test_pipeline_db "$sessioned/pipeline.sqlite" "$sessioned/repo" "fm/alpha||" \
    || { pass "SKIP (python3 unavailable): an absent identity never fabricates a dependence"; return; }

  out=$(certify "$sessioned" --repo "$sessioned/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only || true)
  case "$(squeezed "$out")" in
    *"process not-independent"*)
      fail "absent identity: a dependence was fabricated from an unrecorded identity:"$'\n'"$out" ;;
  esac
  # This run DID record its sessions, so process is observable and reads
  # independent; only the identity dimensions are unobservable.
  assert_contains "$(squeezed "$out")" "process independent" \
    "absent identity: a recorded session stopped being observable"
  assert_contains "$out" "model:could-not-observe" \
    "absent identity: an unrecorded model did not read could-not-observe"
  assert_contains "$out" "vendor:could-not-observe" \
    "absent identity: an unrecorded vendor did not read could-not-observe"

  # The same absent identity on the shape the pipeline actually holds today: no
  # session rows either. Every judged field is empty or zero, and the answer is
  # could-not-observe on every dimension - never a dependence.
  unsessioned=$(make_case absent-identity-unsessioned yes yes)
  fm_test_pipeline_db "$unsessioned/pipeline.sqlite" "$unsessioned/repo" "fm/alpha||||none" \
    || fail "absent identity: the unsessioned fixture failed"
  out=$(certify "$unsessioned" --repo "$unsessioned/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only || true)
  case "$(squeezed "$out")" in
    *"not-independent"*)
      fail "absent identity: a run with no identity and no session reported a dependence:"$'\n'"$out" ;;
  esac
  assert_contains "$out" "process:could-not-observe" \
    "absent identity: a run with no recorded session was not could-not-observe"
  pass "absent reviewing identity never fabricates a dependence"
}

# --- an unmet predicate says what was unmet, and by which predicate ----------

test_an_observed_attestation_failure_is_not_labelled_not_independent() {
  local dir out rc
  dir=$(make_case attestation-unmet no yes)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): an attestation failure is not mislabelled"; return; }
  # A signable route whose attestation verifier REFUSES. Only independence has
  # dimensions, so naming this gap "not-independent" would be a false statement
  # about what went wrong - and fm-decision-surface.sh relays the line verbatim.
  printf '#!/bin/sh\necho "no note covers those bytes"\nexit 1\n' > "$dir/attest"
  chmod +x "$dir/attest"

  out=$(FM_CERTIFY_ATTEST="$dir/attest" certify "$dir" --repo "$dir/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only --head deadbeef) && rc=0 || rc=$?
  [ "$rc" = 3 ] || fail "attestation-unmet: expected an observed-unmet refusal (3), got $rc:"$'\n'"$out"
  assert_contains "$out" "gap=attestation:unmet" \
    "attestation-unmet: the gap did not name the predicate neutrally"
  case "$out" in
    *"attestation:not-independent"*)
      fail "attestation-unmet: an attestation failure was reported as a dependence:"$'\n'"$out" ;;
  esac
  pass "an observed attestation failure names its own predicate, not independence"
}

test_an_unreadable_repository_is_could_not_observe_not_a_refusal() {
  local dir out
  dir=$(make_case attestation-unreadable no yes)
  fm_test_pipeline_db "$dir/pipeline.sqlite" "$dir/repo" "fm/alpha|openai|gpt-5.6-sol" \
    || { pass "SKIP (python3 unavailable): an unreadable repository is could-not-observe"; return; }
  # The head is derived from a live task's worktree while the repository comes
  # from the durable record, so a project directory that moved leaves a head to
  # verify and nowhere to verify it. That reached NO VERDICT, and reporting it
  # as a refusal would be a could-not-observe wearing an observation's words.
  printf '#!/bin/sh\nexit 0\n' > "$dir/attest"
  chmod +x "$dir/attest"

  out=$(FM_CERTIFY_ATTEST="$dir/attest" certify "$dir" --repo "$dir/repo-moved-away" \
    --branch fm/alpha --maker-harness claude --maker-model opus --mode local-only \
    --head deadbeef || true)
  assert_contains "$(squeezed "$out")" "attestation could-not-observe" \
    "unreadable: an unenterable repository was not could-not-observe"
  assert_contains "$out" "repo-moved-away" \
    "unreadable: the refusal did not name the repository it could not read"
  case "$(squeezed "$out")" in
    *"attestation unmet"*)
      fail "unreadable: an unobservable attestation was reported as an observed refusal:"$'\n'"$out" ;;
  esac
  pass "a repository that cannot be entered is could-not-observe, never an observed refusal"
}

test_an_observed_failure_is_never_softened_by_an_unobservable_sibling() {
  local dims certify_fold out rc
  # What nobody could observe may weaken a claim of independence. It may never
  # weaken a FINDING of dependence: reporting a known failure as unmeasured
  # reads as the milder of the two while being strictly worse to act on.

  # ONE: across DIMENSIONS. The reviewer demonstrably shared the fixer's
  # session, and this home declares no vocabulary mapping so the identity
  # dimensions cannot resolve at all. The observed dependence must survive.
  dims=$(make_case observed-over-unobservable yes no)
  fm_test_pipeline_db "$dims/pipeline.sqlite" "$dims/repo" "fm/alpha|openai|gpt-5.6-sol|review|1" \
    || { pass "SKIP (python3 unavailable): an observed failure is never softened"; return; }
  out=$(certify "$dims" --repo "$dims/repo" --branch fm/alpha \
    --maker-harness claude --maker-model opus --mode local-only) && rc=0 || rc=$?
  [ "$rc" = 3 ] || fail "asymmetry: an observed dependence was softened to unmeasured (rc=$rc):"$'\n'"$out"
  assert_contains "$out" "process:not-independent" \
    "asymmetry: the observed dependence was not named"
  assert_contains "$out" "model:could-not-observe" \
    "asymmetry: the unresolvable dimensions were dropped instead of reported beside it"

  # TWO: across PREDICATES. An attestation observed unmet beside an
  # independence nobody could establish must exit as observed-unmet.
  certify_fold=$(make_case observed-over-unobservable-fold no yes)
  printf '#!/bin/sh\necho "no note covers those bytes"\nexit 1\n' > "$certify_fold/attest"
  chmod +x "$certify_fold/attest"
  out=$(FM_CERTIFY_ATTEST="$certify_fold/attest" certify "$certify_fold" \
    --repo "$certify_fold/repo" --branch fm/never-validated \
    --maker-harness claude --maker-model opus --mode local-only --head deadbeef) && rc=0 || rc=$?
  [ "$rc" = 3 ] || fail "asymmetry: an observed unmet predicate reported as unmeasured (rc=$rc):"$'\n'"$out"
  assert_contains "$out" "attestation:unmet" \
    "asymmetry: the observed unmet predicate was not named in the gap"
  assert_contains "$out" "independence(" \
    "asymmetry: the unobservable predicate was dropped from the gap"
  pass "an observed failure outranks an unobservable sibling, and both are still named"
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
test_a_review_with_no_recorded_session_is_could_not_observe
test_one_unobserved_run_is_not_masked_by_a_sibling_that_recorded_one
test_an_absent_reviewing_identity_never_becomes_evidence
test_an_observed_attestation_failure_is_not_labelled_not_independent
test_an_unreadable_repository_is_could_not_observe_not_a_refusal
test_an_observed_failure_is_never_softened_by_an_unobservable_sibling
test_undeclared_mapping_refuses_rather_than_inferring
test_not_applicable_is_carried_with_its_route
test_not_applicable_is_distinct_from_unobserved_on_the_same_predicate
test_no_argument_can_assert_a_certification_result
test_historical_records_are_never_backfilled
test_json_form_carries_every_dimension_and_the_route
