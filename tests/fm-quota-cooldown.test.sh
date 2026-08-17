#!/usr/bin/env bash
# Behavior tests for durable quota cooldown recording and authorization.
#
# The owner CLI is exercised only through its public commands. Fixed clocks make
# expiry behavior deterministic without pruning or rewriting the durable file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

COOLDOWN="$ROOT/bin/fm-quota-cooldown.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-cooldown)

make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/data"
  printf '%s\n' "$home"
}

record_family() {
  local home=$1 family=$2 expires=$3
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope model-family --harness cursor-agent \
    --provider cursor --model-family "$family" \
    --evidence-kind provider-refusal \
    --evidence "You've hit your usage limit for $family; resets 9/14/2026" \
    --expires-at "$expires"
}

authorize() {
  local home=$1 family=$2
  shift 2
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent --provider cursor \
    --model-family "$family" "$@"
}

# assert_record <home> <jq filter> <msg>: the durable record, read through the
# owner's serialized `list --json` contract, must satisfy <jq filter>.
assert_record() {
  local home=$1 filter=$2 msg=$3 record
  record=$(FM_HOME="$home" "$COOLDOWN" list --json) || fail "$msg (list --json failed)"
  printf '%s' "$record" | jq -e "$filter" >/dev/null \
    || fail "$msg"$'\n'"--- record ---"$'\n'"$record"
}

test_active_family_cooldown_suppresses_automatic_candidate() {
  local home out status
  home=$(make_home active)
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record active cooldown"

  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 3 "$status" "active cooldown should suppress an automatic candidate"
  assert_contains "$out" "routing cooldown active" "suppression did not name the active cooldown"
  assert_contains "$out" "2026-09-14T00:00:00.000Z" "suppression did not show automatic expiry"
  pass "active family cooldown suppresses an automatic candidate"
}

test_expired_cooldown_does_not_suppress() {
  local home out status
  home=$(make_home expired)
  record_family "$home" glm 2026-08-16T12:01:00Z >/dev/null || fail "could not record expiring cooldown"

  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 0 "$status" "expired cooldown should not suppress a candidate"
  [ -z "$out" ] || fail "expired cooldown emitted an authorization warning: $out"
  pass "expired cooldown stops suppressing automatically"
}

test_family_scope_does_not_suppress_sibling() {
  local home out status
  home=$(make_home sibling)
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record family cooldown"

  out=$(authorize "$home" kimi 2>&1)
  status=$?
  expect_code 0 "$status" "a model-family cooldown should not suppress its sibling family"
  [ -z "$out" ] || fail "sibling family emitted an authorization warning: $out"
  pass "model-family cooldown leaves sibling families on the same provider eligible"
}

test_explicit_override_is_authorized_and_recorded() {
  local home out status
  home=$(make_home override)
  record_family "$home" kimi 2026-09-14T00:00:00Z >/dev/null || fail "could not record override cooldown"

  out=$(authorize "$home" kimi --task-id paid-retry \
    --override-reason "captain raised the Cursor spend limit" 2>&1)
  status=$?
  expect_code 0 "$status" "explicit captain override should authorize a cooled tuple"
  assert_contains "$out" "routing cooldown overridden" "override did not report the departure"
  assert_record "$home" \
    '[.cooldowns[] | select(.scope.model_family == "kimi") | .overrides[]
      | select(.task_id == "paid-retry"
        and .reason == "captain raised the Cursor spend limit")] | length == 1' \
    "cooldown record did not note the overriding task and reason exactly once"
  pass "explicit captain override dispatches and is recorded on the cooldown"
}

test_provider_scope_suppresses_every_family() {
  local home out status
  home=$(make_home provider)
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope provider --provider cursor \
    --evidence-kind quota-axi \
    --evidence "cursor all_models effectivePercentRemaining=0" \
    --expires-at 2026-09-14T00:00:00Z >/dev/null || fail "could not record provider cooldown"

  out=$(authorize "$home" grok 2>&1)
  status=$?
  expect_code 3 "$status" "provider cooldown should suppress every family on that provider"
  pass "provider-wide proof suppresses every family on that provider"
}

test_unrelated_provider_stays_eligible_without_the_family_axis() {
  local home out status
  home=$(make_home unrelated-provider)
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record family cooldown"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent --provider bedrock 2>&1)
  status=$?
  expect_code 0 "$status" "a cooldown on another provider must stay inert without the family axis"
  [ -z "$out" ] || fail "unrelated provider emitted an authorization warning: $out"
  pass "a cooldown proven on another provider never demands the family axis"
}

test_missing_family_axis_fails_closed_on_the_proven_provider() {
  local home out status
  home=$(make_home missing-family)
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record family cooldown"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent --provider cursor 2>&1)
  status=$?
  expect_code 3 "$status" "a cooldown that could match must fail closed on the missing family axis"
  assert_contains "$out" "--model-family" "fail-closed refusal did not name the missing axis"
  assert_contains "$out" "--dispatch-model-family" "fail-closed refusal did not name the spawn flag that supplies it"
  pass "an active cooldown that could match fails closed on a missing family axis"
}

test_ambiguous_expiry_is_refused_before_any_record() {
  local home out status form
  home=$(make_home ambiguous-expiry)

  for form in 9/14/2026 2026-09-14T00:00:00 "Sep 14 2026" 2026-09-14T00:00:00+0200; do
    out=$(record_family "$home" glm "$form" 2>&1)
    status=$?
    expect_code 2 "$status" "an expiry without an unambiguous zone should be refused: $form"
    assert_contains "$out" "zone-qualified ISO-8601" \
      "refusal did not state the required expiry form for: $form"
  done
  assert_absent "$home/data/quota-cooldowns.json" \
    "a refused ambiguous expiry still created a durable record"

  record_family "$home" glm 2026-09-14T00:00:00-04:00 >/dev/null \
    || fail "an offset-qualified expiry should record"
  assert_record "$home" '.cooldowns[0].expires_at == "2026-09-14T04:00:00.000Z"' \
    "an offset-qualified expiry was not stored as the instant it names"

  record_family "$home" glm 2026-09-14 >/dev/null || fail "a bare date expiry should record"
  assert_record "$home" '.cooldowns[0].expires_at == "2026-09-14T00:00:00.000Z"' \
    "a bare YYYY-MM-DD expiry was not stored as its UTC instant"
  pass "an expiry that depends on the recording machine's timezone is refused"
}

test_override_outranks_the_missing_axis_refusal() {
  local home out status
  home=$(make_home override-axes)
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record family cooldown"
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope provider --provider cursor \
    --evidence-kind quota-axi \
    --evidence "cursor all_models effectivePercentRemaining=0" \
    --expires-at 2026-09-14T00:00:00Z >/dev/null || fail "could not record provider cooldown"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent 2>&1)
  status=$?
  expect_code 3 "$status" "automatic selection without the axes must still fail closed"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent --task-id unscoped-retry \
    --override-reason "captain accepted the risk without the catalog axes" 2>&1)
  status=$?
  expect_code 0 "$status" "an explicit override must not be blocked by the missing-axis refusal"
  assert_record "$home" '[.cooldowns[].overrides[]] | length == 0' \
    "an override that identified no record still wrote a departure onto one"

  out=$(authorize "$home" glm --task-id scoped-retry \
    --override-reason "captain accepted the risk with the catalog axes" 2>&1)
  status=$?
  expect_code 0 "$status" "an explicit override should dispatch the cooled tuple"
  assert_record "$home" \
    '[.cooldowns[] | select([.overrides[] | select(.task_id == "scoped-retry")] | length == 1)]
      | length == 2' \
    "the override was not recorded on every active record its axes identified"
  pass "an explicit captain override is evaluated before the missing-axis refusal"
}

test_axis_case_variants_do_not_fail_open() {
  local home out status
  home=$(make_home axis-case)
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:00:00Z \
    "$COOLDOWN" record --scope model-family --harness Cursor-Agent \
    --provider Cursor --model-family GLM \
    --evidence-kind provider-refusal \
    --evidence "You've hit your usage limit for GLM; resets 9/14/2026" \
    --expires-at 2026-09-14T00:00:00Z >/dev/null \
    || fail "could not record a cooldown whose evidence named mixed-case axes"

  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 3 "$status" "a mixed-case recorded axis must still suppress its own tuple"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:05:00Z \
    "$COOLDOWN" authorize --harness cursor-agent --provider "  CURSOR " --model-family " Glm" 2>&1)
  status=$?
  expect_code 3 "$status" "a mixed-case or padded dispatch axis must still be suppressed"

  out=$(authorize "$home" kimi 2>&1)
  status=$?
  expect_code 0 "$status" "canonical axis matching must still leave a sibling family eligible"

  record_family "$home" GLM 2026-09-20T00:00:00Z >/dev/null \
    || fail "could not re-record the same scope under a different case"
  assert_record "$home" '.cooldowns | length == 1' \
    "a case variant of one proven scope created a second entry instead of replacing it"
  assert_record "$home" \
    '.cooldowns[0].scope | .provider == "cursor" and .harness == "cursor-agent" and .model_family == "glm"' \
    "the durable record did not store canonical axis names"
  pass "provider, harness, and model-family axes match by canonical identity"
}

test_recover_only_quarantines_a_store_proven_invalid() {
  local home out status file corrupt quarantined
  home=$(make_home recover)
  file="$home/data/quota-cooldowns.json"
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not record cooldown"

  out=$(FM_HOME="$home" "$COOLDOWN" recover 2>&1)
  status=$?
  expect_code 2 "$status" "recover must refuse a store that still validates"
  assert_contains "$out" "valid cooldown store" "recover did not report why it refused"
  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 3 "$status" "a refused recover must leave every live suppression in place"

  corrupt='{"schema_version":1,"cooldowns":[{'
  printf '%s' "$corrupt" > "$file"
  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 2 "$status" "an unreadable store must refuse authorization"
  assert_contains "$out" "recover" "the refusal did not name the owner's recovery command"

  out=$(FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-08-16T12:30:00Z "$COOLDOWN" recover 2>&1)
  status=$?
  expect_code 0 "$status" "recover should quarantine a store proven invalid: $out"
  quarantined="$file.corrupt.2026-08-16T12-30-00-000Z"
  assert_present "$quarantined" "recover did not preserve the invalid bytes for diagnosis"
  [ "$(cat "$quarantined")" = "$corrupt" ] \
    || fail "the quarantined file does not hold the original invalid bytes"
  assert_contains "$out" "$quarantined" "recover did not report where the invalid bytes went"
  assert_record "$home" '.schema_version == 1 and (.cooldowns | length == 0)' \
    "recover did not leave a valid empty store behind"

  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 0 "$status" "a recovered store must stop suppressing until cooldowns are recorded again"
  record_family "$home" glm 2026-09-14T00:00:00Z >/dev/null || fail "could not re-record after recovery"
  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 3 "$status" "the cooldown recorded again after recovery should suppress"
  pass "recover quarantines only a store proven invalid and leaves the owner recording again"
}

test_refused_write_leaves_the_owner_usable() {
  local home out status lock
  home=$(make_home wedged)
  printf '%s' '{"schema_version":1,"cooldowns":[{' > "$home/data/quota-cooldowns.json"

  out=$(record_family "$home" glm 2026-09-14T00:00:00Z 2>&1)
  status=$?
  expect_code 2 "$status" "a truncated durable file should refuse the record"
  lock="$home/data/quota-cooldowns.json.lock"
  { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } \
    || fail "a refused record left its durable write lock behind"

  FM_HOME="$home" "$COOLDOWN" recover >/dev/null 2>&1 \
    || fail "the owner could not recover the wedged store"
  out=$(record_family "$home" glm 2026-09-14T00:00:00Z 2>&1)
  status=$?
  expect_code 0 "$status" "the owner should still record after a refused write: $out"

  out=$(authorize "$home" glm 2>&1)
  status=$?
  expect_code 3 "$status" "the re-recorded cooldown should suppress automatic selection"
  pass "a refused durable write leaves the owner able to record and override again"
}

test_active_family_cooldown_suppresses_automatic_candidate
test_expired_cooldown_does_not_suppress
test_family_scope_does_not_suppress_sibling
test_explicit_override_is_authorized_and_recorded
test_provider_scope_suppresses_every_family
test_unrelated_provider_stays_eligible_without_the_family_axis
test_missing_family_axis_fails_closed_on_the_proven_provider
test_ambiguous_expiry_is_refused_before_any_record
test_override_outranks_the_missing_axis_refusal
test_axis_case_variants_do_not_fail_open
test_recover_only_quarantines_a_store_proven_invalid
test_refused_write_leaves_the_owner_usable

echo "# all fm-quota-cooldown tests passed"
