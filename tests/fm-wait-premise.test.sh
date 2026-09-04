#!/usr/bin/env bash
# Behavior tests for declared wait premises and their shadow metrics.
#
# The tests use fixture status logs and the public wait/report commands. A fake
# gh answers the existing PR poll owner's read without making a network request.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAIT="$ROOT/bin/fm-wait-premise.sh"
QUOTA="$ROOT/bin/fm-quota-cooldown.sh"
TMP_ROOT=$(fm_test_tmproot fm-wait-premise)
PR_URL=https://github.com/pedromuller-del/firstmate/pull/3541

make_home() {
  local home="$TMP_ROOT/$1/home" fakebin
  fakebin="$TMP_ROOT/$1/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/config" "$fakebin"
  printf '%s\n' '{"pools":[{"pool":"test","provider":"cursor","plan":"test","harness":"cursor-agent","account":"test","models":["test-model"],"quota_readable":true,"gap":"","note":""}]}' \
    > "$home/config/model-catalog.json"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAKE_PR_SLEEP:-}" ]; then sleep "$FAKE_PR_SLEEP"; fi
case "${FAKE_PR_STATE:-OPEN}" in
  MERGED|OPEN|CLOSED) printf '%s\n' "${FAKE_PR_STATE}" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$home"
}

record_provider_cooldown() {
  local home=$1 expires=$2
  FM_HOME="$home" FM_QUOTA_COOLDOWN_NOW=2026-09-02T10:00:00Z \
    "$QUOTA" record --scope provider --provider cursor \
    --evidence-kind quota-axi --evidence 'cursor provider window exhausted' \
    --expires-at "$expires" >/dev/null
}

test_pr_and_quota_verdicts() {
  local home fakebin out status
  home=$(make_home verdicts)
  fakebin="$TMP_ROOT/verdicts/fakebin"
  printf 'paused: waiting for the fork PR wait=pr:%s\n' "$PR_URL" > "$home/state/pr-task.status"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=OPEN FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" pr-task)
  status=$?
  expect_code 0 "$status" "an open PR premise should be readable"
  [ "$out" = still-waiting ] || fail "open PR premise verdict was not still-waiting: $out"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=OPEN FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" --shadow-row pr-task)
  [ "$out" = $'wait=pr:'"$PR_URL"$'\tstill-waiting\t1' ] \
    || fail "shadow row did not preserve premise, verdict, and pause occurrence: $out"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=MERGED FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" pr-task)
  status=$?
  expect_code 0 "$status" "a merged PR premise should be readable"
  [ "$out" = expired ] || fail "merged PR premise verdict was not expired: $out"

  printf 'paused: awaiting review of PR %s\n' "$PR_URL" > "$home/state/legacy-pr.status"
  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=OPEN FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" legacy-pr)
  status=$?
  expect_code 0 "$status" "a legacy paused PR URL should be readable"
  [ "$out" = still-waiting ] || fail "legacy PR URL verdict was not still-waiting: $out"

  printf 'paused: waiting for quota reset wait=quota:cursor\n' > "$home/state/quota-task.status"
  record_provider_cooldown "$home" 2026-09-03T00:00:00Z \
    || fail "could not create the active quota fixture"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_QUOTA_COOLDOWN_NOW=2026-09-02T12:00:00Z "$WAIT" quota-task)
  status=$?
  expect_code 0 "$status" "an active quota premise should be readable"
  [ "$out" = still-waiting ] || fail "active quota premise verdict was not still-waiting: $out"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_QUOTA_COOLDOWN_NOW=2026-09-04T00:00:00Z "$WAIT" quota-task)
  status=$?
  expect_code 0 "$status" "an expired quota premise should be readable"
  [ "$out" = expired ] || fail "expired quota premise verdict was not expired: $out"
  pass "wait premise checks delegate PR and quota verdicts to their existing owners"
}

test_unbindable_pause_is_explicit() {
  local home out status
  home=$(make_home unbindable)
  printf 'paused: waiting for a human decision\n' > "$home/state/unbound.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$WAIT" unbound)
  status=$?
  expect_code 0 "$status" "an unbound pause should be a normal verdict"
  [ "$out" = unbindable ] || fail "pause without a premise was not unbindable: $out"
  pass "a pause without a machine-readable premise is unbindable"
}

test_owner_failures_are_silent_and_bounded() {
  local home fakebin out status
  home=$(make_home owner-failures)
  fakebin="$TMP_ROOT/owner-failures/fakebin"
  printf 'paused: waiting for the fork PR wait=pr:%s\n' "$PR_URL" > "$home/state/pr-task.status"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=CLOSED FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" pr-task)
  status=$?
  expect_code 0 "$status" "a closed PR owner result should not fail the command"
  [ -z "$out" ] || fail "a closed PR owner result was misreported: $out"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=FAILED FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$WAIT" pr-task)
  status=$?
  expect_code 0 "$status" "an unreadable PR owner result should not fail the command"
  [ -z "$out" ] || fail "an unreadable PR owner result was misreported: $out"

  out=$(PATH="$fakebin:$PATH" FAKE_PR_STATE=OPEN FAKE_PR_SLEEP=3 \
    FM_WAIT_PREMISE_TIMEOUT=1 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$WAIT" pr-task)
  status=$?
  expect_code 0 "$status" "a timed-out PR owner result should not fail the command"
  [ -z "$out" ] || fail "a timed-out PR owner result was misreported: $out"
  pass "closed, unreadable, and timed-out owner lookups stay silent"
}

test_unknown_quota_provider_is_unbindable() {
  local home out status
  home=$(make_home unknown-quota)
  printf 'paused: waiting for quota reset wait=quota:definitely-not-a-provider\n' \
    > "$home/state/quota-task.status"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$WAIT" quota-task)
  status=$?
  expect_code 0 "$status" "an unknown quota provider should be a normal verdict"
  [ "$out" = unbindable ] || fail "an unknown quota provider was classified as: $out"
  pass "an unknown quota provider is not treated as an expired wait"
}

test_report_counts_bound_and_expiry_outcomes() {
  local home out status
  home=$(make_home report)
  printf 'paused: waiting for PR wait=pr:%s\nworking: correction visible\n' "$PR_URL" \
    > "$home/state/true.status"
  printf 'paused: waiting for quota wait=quota:cursor\nworking: correction visible\npaused: still waiting wait=quota:cursor\n' \
    > "$home/state/false.status"
  printf 'paused: no checkable premise\n' > "$home/state/unbound.status"
  printf '2026-09-02T10:00:00Z\ttrue\twait=pr:%s\texpired\t1\n' "$PR_URL" \
    > "$home/state/wait-events.log"
  printf '2026-09-02T10:00:00Z\tfalse\twait=quota:cursor\texpired\t3\n' \
    >> "$home/state/wait-events.log"
  printf '2026-09-02T10:01:00Z\ttrue\twait=pr:%s\tcorrected\t1\n' "$PR_URL" \
    > "$home/state/wait-corrections.log"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$WAIT" report)
  status=$?
  expect_code 0 "$status" "wait premise report should read fixture state"
  assert_contains "$out" 'bound-share=3/4' "report did not count bound pauses"
  assert_contains "$out" 'true-expiries=1' "report did not count true expiries"
  assert_contains "$out" 'false-expiries=1' "report did not count false expiries"
  assert_contains "$out" 'time-to-correction-seconds count=1 total=60 average=60' \
    "report did not expose correction latency coverage"
  pass "wait premise report counts binding, true expiry, false expiry, and correction latency"
}

test_pr_and_quota_verdicts
test_unbindable_pause_is_explicit
test_owner_failures_are_silent_and_bounded
test_unknown_quota_provider_is_unbindable
test_report_counts_bound_and_expiry_outcomes

echo '# all fm-wait-premise tests passed'
