#!/usr/bin/env bash
# Behavior tests for deterministic five-factor Codex worker routing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUTE="$ROOT/bin/fm-task-model-route.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-model-route)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data"

route() {
  FM_HOME="$HOME_DIR" "$ROUTE" "$@"
}

test_score_bands_and_evidence_record() {
  local out record
  out=$(route luna-task \
    --ambiguity 0 --ambiguity-evidence 'requirements are explicit' \
    --boundary-clarity 0 --boundary-clarity-evidence 'one public command owns the change' \
    --risk 0 --risk-evidence 'no persistent state changes' \
    --diagnosis 0 --diagnosis-evidence 'no defect investigation is needed' \
    --verification 0 --verification-evidence 'one deterministic test proves behavior') \
    || fail "Luna route failed: $out"
  assert_contains "$out" "model=gpt-5.6-luna effort=medium" \
    "score 0 did not select Luna medium"
  record="$HOME_DIR/data/luna-task/model-routing.tsv"
  assert_grep $'ambiguity\t0\trequirements are explicit' "$record" \
    "routing record omitted ambiguity evidence"
  assert_grep $'boundary_clarity\t0\tone public command owns the change' "$record" \
    "routing record omitted boundary-clarity evidence"
  assert_grep $'diagnosis_need\t0\tno defect investigation is needed' "$record" \
    "routing record omitted diagnosis-need evidence"
  assert_grep $'verification_quality\t0\tone deterministic test proves behavior' "$record" \
    "routing record omitted verification-quality evidence"
  assert_grep $'total\t0' "$record" "routing record omitted the total"
  assert_grep $'override_model\tnone' "$record" \
    "routing record omitted the explicit no-override value"
  assert_grep $'override_effort\tnone' "$record" \
    "routing record omitted the explicit no-override effort"

  out=$(route terra-task \
    --ambiguity 1 --ambiguity-evidence a \
    --boundary-clarity 1 --boundary-clarity-evidence b \
    --risk 1 --risk-evidence c \
    --diagnosis 0 --diagnosis-evidence d \
    --verification 0 --verification-evidence e) \
    || fail "Terra route failed: $out"
  assert_contains "$out" "model=gpt-5.6-terra effort=high" \
    "score 3 did not select Terra high"

  out=$(route sol-task \
    --ambiguity 2 --ambiguity-evidence a \
    --boundary-clarity 2 --boundary-clarity-evidence b \
    --risk 2 --risk-evidence c \
    --diagnosis 1 --diagnosis-evidence d \
    --verification 0 --verification-evidence e) \
    || fail "Sol route failed: $out"
  assert_contains "$out" "model=gpt-5.6-sol effort=high" \
    "score 7 did not select Sol high"
  pass "five recorded factors deterministically select Luna, Terra, or Sol"
}

test_floors_and_user_override_precedence() {
  local out record
  out=$(route floor-task \
    --ambiguity 0 --ambiguity-evidence a \
    --boundary-clarity 0 --boundary-clarity-evidence b \
    --risk 0 --risk-evidence c \
    --diagnosis 0 --diagnosis-evidence d \
    --verification 0 --verification-evidence e \
    --floor architecture) \
    || fail "Sol floor route failed: $out"
  assert_contains "$out" "model=gpt-5.6-sol effort=high" \
    "architecture floor did not raise a Luna score to Sol"

  # An explicit captain override is the highest-precedence input and is recorded.
  out=$(route override-task \
    --ambiguity 0 --ambiguity-evidence a \
    --boundary-clarity 0 --boundary-clarity-evidence b \
    --risk 0 --risk-evidence c \
    --diagnosis 0 --diagnosis-evidence d \
    --verification 0 --verification-evidence e \
    --floor architecture \
    --override-model gpt-5.6-terra --override-effort ultra) \
    || fail "explicit override route failed: $out"
  assert_contains "$out" "model=gpt-5.6-terra effort=ultra" \
    "explicit override did not win deterministic precedence"
  record="$HOME_DIR/data/override-task/model-routing.tsv"
  assert_grep $'precedence\tuser_override' "$record" \
    "routing record did not make override precedence inspectable"
  assert_grep $'override_model\tgpt-5.6-terra' "$record" \
    "routing record did not persist the explicit model override"
  assert_grep $'override_effort\tultra' "$record" \
    "routing record did not persist the explicit effort override"

  # Luna does not support ultra in the host-supported model catalog.
  set +e
  out=$(route invalid-effort \
    --ambiguity 0 --ambiguity-evidence a \
    --boundary-clarity 0 --boundary-clarity-evidence b \
    --risk 0 --risk-evidence c \
    --diagnosis 0 --diagnosis-evidence d \
    --verification 0 --verification-evidence e \
    --override-model gpt-5.6-luna --override-effort ultra 2>&1)
  status=$?
  set -e
  expect_code 2 "$status" "unsupported model/effort pair must be refused"
  assert_contains "$out" "gpt-5.6-luna does not support effort ultra" \
    "unsupported effort refusal was not diagnostic"
  pass "hard floors and explicit user override have deterministic precedence"
}

test_score_bands_and_evidence_record
test_floors_and_user_override_precedence
echo "# all task model route tests passed"
