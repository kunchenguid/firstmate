#!/usr/bin/env bash
# tests/fm-away-decision-class.test.sh - the D0-D3 classifier
# (bin/fm-decision-class.sh).
#
# The property this file exists to pin is the commission's central separation:
# uncertainty is a capability-routing problem, operator escalation is an
# authority condition. So the exhaustive sweep below walks the ENTIRE capability
# input space - confidence, novelty, number of reasonable options, blast radius,
# and whether a standing rule applies - with every authority predicate set to no,
# and requires that not one combination produces D3.
#
# That sweep is worthless on its own: a classifier that never emitted D3 at all
# would pass it. So it is paired with a negative control that flips exactly one
# authority predicate across the same combinations and requires D3 every time.
#
# Also covered: each tier's own entry condition, each authority predicate
# individually, the two Population-before-Expansion outcomes, the interaction
# where a standing rule covers an otherwise-irreversible decision, and the
# ledger record a classification leaves behind.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CLASS="$ROOT/bin/fm-decision-class.sh"
SESSION="$ROOT/bin/fm-away-session.sh"
TMP_ROOT=$(fm_test_tmproot fm-away-decision-class-tests)
trap fm_test_cleanup EXIT

tier_of() {  # <classify args...>
  "$CLASS" classify "$@" | sed -n 's/^tier=//p'
}

expect_tier() {  # <expected> <label> <classify args...>
  local want=$1 label=$2 got
  shift 2
  got=$(tier_of "$@")
  [ "$got" = "$want" ] || fail "$label: got $got, expected $want"
}

# --- per-tier entry conditions ----------------------------------------------

test_d1_is_the_default_for_ordinary_engineering() {
  expect_tier D1 'ordinary reversible in-architecture work' \
    --reversible yes --within-architecture yes --blast-radius contained
  pass "an ordinary reversible in-architecture decision is delegated engineering judgment"
}

test_d0_when_a_standing_rule_determines_it() {
  expect_tier D0 'standing rule applies' --standing-rule 'AGENTS.md section 7'
  pass "a decision an accepted rule already answers is deterministic, not a judgment call"
}

test_each_capability_signal_routes_to_d2_alone() {
  expect_tier D2 'low confidence' --confidence low
  expect_tier D2 'novel' --novel yes
  expect_tier D2 'several reasonable options' --options 3
  expect_tier D2 'broad blast radius' --blast-radius broad
  pass "each capability signal on its own routes to assisted judgment, never to the operator"
}

test_each_authority_predicate_reserves_alone() {
  expect_tier D3 'authority reassignment' --reassigns-authority yes
  expect_tier D3 'constitutional change' --constitutional yes
  expect_tier D3 'operator-reserved gate' --operator-reserved-gate yes
  expect_tier D3 'credentials' --credentials yes
  expect_tier D3 'external side effects' --external-effect yes
  expect_tier D3 'destructive action' --destructive yes
  expect_tier D3 'weakens certification' --weakens-certification yes
  expect_tier D3 'irreversible with no covering rule' --reversible no
  pass "each reserved-authority predicate on its own reserves the decision to the operator"
}

test_population_before_expansion_decides_an_expansion() {
  expect_tier D3 'expansion PbE did not resolve' --within-architecture no --pbe-resolved no
  expect_tier D1 'expansion PbE resolved by populating a primitive' \
    --within-architecture no --pbe-resolved yes
  pass "an architectural expansion is operator-reserved only when Population-before-Expansion cannot resolve it"
}

test_a_standing_rule_covers_an_irreversible_decision() {
  # "Irreversible" reserves only when it is BEYOND standing authority. A rule
  # that already covers it makes the disposition deterministic instead.
  expect_tier D3 'irreversible, uncovered' --reversible no
  expect_tier D0 'irreversible, covered by a standing rule' \
    --reversible no --standing-rule 'release policy: tags are never rewritten'
  pass "an irreversible decision a standing rule already covers is deterministic, not operator-reserved"
}

# --- the property, and its negative control ---------------------------------

capability_space() {
  local confidence novel options blast standing
  for confidence in high medium low; do
    for novel in no yes; do
      for options in 1 2 3 5; do
        for blast in contained broad; do
          for standing in none 'ADR-0012 module boundaries'; do
            printf '%s\t%s\t%s\t%s\t%s\n' "$confidence" "$novel" "$options" "$blast" "$standing"
          done
        done
      done
    done
  done
}

test_no_capability_signal_can_reserve_a_decision() {
  local confidence novel options blast standing tier count=0
  while IFS=$'\t' read -r confidence novel options blast standing; do
    tier=$(tier_of --confidence "$confidence" --novel "$novel" --options "$options" \
      --blast-radius "$blast" --standing-rule "$standing")
    count=$((count + 1))
    [ "$tier" != D3 ] || fail \
      "capability inputs alone produced D3 (confidence=$confidence novel=$novel options=$options blast=$blast standing=$standing)"
  done <<EOF
$(capability_space)
EOF
  [ "$count" -ge 96 ] || fail "the capability sweep only covered $count combinations"
  pass "no combination of low confidence, novelty, option count or blast radius creates an operator gate ($count combinations)"
}

test_negative_control_one_authority_predicate_always_reserves() {
  local confidence novel options blast standing tier count=0
  while IFS=$'\t' read -r confidence novel options blast standing; do
    tier=$(tier_of --confidence "$confidence" --novel "$novel" --options "$options" \
      --blast-radius "$blast" --standing-rule "$standing" --credentials yes)
    count=$((count + 1))
    [ "$tier" = D3 ] || fail \
      "an authority predicate failed to reserve (confidence=$confidence novel=$novel options=$options blast=$blast standing=$standing) -> $tier"
  done <<EOF
$(capability_space)
EOF
  pass "the same $count combinations DO reach D3 once one authority predicate is set, so the sweep above is not vacuous"
}

# --- evidence ---------------------------------------------------------------

test_classification_is_recorded_against_the_away_session() {
  local home line
  home="$TMP_ROOT/record"
  mkdir -p "$home/state" "$home/data"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_AWAY_LAUNCH_MODE=start-native \
    "$SESSION" start --intent afk >/dev/null 2>&1

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CLASS" classify --task widget-api --key shape --confidence low --record >/dev/null
  line=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$SESSION" ledger classification)
  case "$line" in
    *"task=widget-api"*"key=shape"*"tier=D2"*"authority=delegated"*) : ;;
    *) fail "the recorded classification did not carry the task, key, tier and authority: $line" ;;
  esac
  case "$line" in
    *"escalators=confidence-low"*) : ;;
    *) fail "the record did not name the capability signal that caused the routing: $line" ;;
  esac

  # Recording needs an open away session; without one it must refuse rather than
  # write the evidence somewhere else.
  local other="$TMP_ROOT/record-no-session"
  mkdir -p "$other/state"
  if FM_HOME="$other" FM_STATE_OVERRIDE="$other/state" \
    "$CLASS" classify --task t --key k --record >/dev/null 2>&1; then
    fail "a classification was recorded with no away session open"
  fi
  pass "a classification is recorded as away-session evidence, and refuses when there is no session"
}

test_d1_is_the_default_for_ordinary_engineering
test_d0_when_a_standing_rule_determines_it
test_each_capability_signal_routes_to_d2_alone
test_each_authority_predicate_reserves_alone
test_population_before_expansion_decides_an_expansion
test_a_standing_rule_covers_an_irreversible_decision
test_no_capability_signal_can_reserve_a_decision
test_negative_control_one_authority_predicate_always_reserves
test_classification_is_recorded_against_the_away_session

echo "# fm-away-decision-class.test.sh: all assertions passed"
