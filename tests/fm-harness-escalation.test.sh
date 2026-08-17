#!/usr/bin/env bash
# Behavior tests for `fm-harness.sh escalate`: the classifying routing-escalation
# ladder used by stuck-crewmate-recovery.
#
# Every assertion pins the RESOLVED TUPLE the ladder prints (harness=/model=/
# effort= plus the verdict), never an internal call: a ladder with inverted tier
# logic must fail these tests.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-escalation)

# make_home <name>: an isolated fake home with the dirs escalate reads/writes.
make_home() {
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  printf '%s\n' "$home"
}

# write_task_meta <home> <id> <key=val>...
write_task_meta() {
  local home=$1 id=$2
  shift 2
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$TMP_ROOT/wt-$id" \
    "project=$TMP_ROOT/proj-$id" \
    "$@"
}

# run_escalate <home> <id> <class> <outfile> <statusfile>: combined output
# lands in <outfile>, the ladder's exit status as one line in <statusfile>.
run_escalate() {
  local home=$1 id=$2 class=$3 outfile=$4 statusfile=$5
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" \
    "$HARNESS" escalate "$id" --class "$class" > "$outfile" 2>&1
  printf '%s\n' "$?" > "$statusfile"
}

# esc <home> <id> <class>: runs the ladder and prints its combined output; the
# exit status is readable afterwards as $(esc_status).
ESC_STATUS_FILE="$TMP_ROOT/esc.status"
esc() {
  run_escalate "$1" "$2" "$3" "$TMP_ROOT/esc.out" "$ESC_STATUS_FILE"
  cat "$TMP_ROOT/esc.out"
}
esc_status() { cat "$ESC_STATUS_FILE"; }

# meta_field <file> <key>
meta_field() {
  grep "^$2=" "$1" | tail -1 | cut -d= -f2-
}

# assert_tuple <output> <harness> <model> <effort>
assert_tuple() {
  assert_contains "$1" "harness=$2" "resolved tuple harness"
  assert_contains "$1" "model=$3" "resolved tuple model"
  assert_contains "$1" "effort=$4" "resolved tuple effort"
}

test_substantive_failure_raises_default_effort_one_rung() {
  local home id out
  home=$(make_home sub-default); id=sub-default-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=default routing_source=fallback

  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "substantive escalation of a fallback tuple"
  assert_contains "$out" "verdict=relaunch" "substantive failure should relaunch"
  assert_contains "$out" "attempts=1" "first escalation should count attempt 1"
  assert_tuple "$out" codex default medium
  assert_grep "substantive" "$home/state/$id.escalation" "escalation log missing the substantive event"
  assert_grep "relaunch" "$home/state/$id.escalation" "escalation log missing the relaunch verdict"
  pass "substantive failure on a fallback tuple raises default effort to medium, harness and model unchanged"
}

test_substantive_failure_climbs_rungs_then_stops_below_max() {
  local home id out
  home=$(make_home sub-climb); id=sub-climb-a1
  write_task_meta "$home" "$id" harness=pi kind=ship model=default effort=low routing_source=fallback

  out=$(esc "$home" "$id" substantive)
  assert_tuple "$out" pi default medium
  assert_not_contains "$out" "effort=max" "ladder selected max automatically"
  fm_write_meta "$home/state/$id.meta" window=w endpoint_task_id=$id worktree=w project=p \
    harness=pi kind=ship model=default effort=medium routing_source=fallback

  out=$(esc "$home" "$id" substantive)
  assert_tuple "$out" pi default high
  assert_not_contains "$out" "effort=max" "ladder selected max automatically"
  fm_write_meta "$home/state/$id.meta" window=w endpoint_task_id=$id worktree=w project=p \
    harness=pi kind=ship model=default effort=high routing_source=fallback

  out=$(esc "$home" "$id" substantive)
  assert_tuple "$out" pi default xhigh
  assert_not_contains "$out" "effort=max" "ladder selected max automatically"
  fm_write_meta "$home/state/$id.meta" window=w endpoint_task_id=$id worktree=w project=p \
    harness=pi kind=ship model=default effort=xhigh routing_source=fallback

  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "ceiling escalation should still resolve cleanly"
  assert_contains "$out" "verdict=escalate-captain" "top rung must stop and escalate to a human"
  assert_contains "$out" "reason=effort-ceiling" "ceiling verdict must name its reason"
  assert_not_contains "$out" "verdict=relaunch" "top rung must not emit another relaunch"
  assert_not_contains "$out" "effort=max" "ladder selected max automatically"
  pass "substantive failures climb low->medium->high->xhigh and stop at a human escalation, never max"
}

test_mechanical_failure_relaunches_same_tuple() {
  local home id out
  home=$(make_home mech); id=mech-a1
  write_task_meta "$home" "$id" harness=grok kind=ship model=default effort=high routing_source=fallback

  out=$(esc "$home" "$id" mechanical)
  expect_code 0 "$(esc_status)" "mechanical escalation of a fallback tuple"
  assert_contains "$out" "verdict=relaunch" "mechanical failure should relaunch"
  assert_tuple "$out" grok default high
  assert_grep "mechanical" "$home/state/$id.escalation" "escalation log missing the mechanical event"
  pass "mechanical failure relaunches the identical tuple (no tier change) and still counts the attempt"
}

test_injection_refusal_rotates_harness_and_preserves_tier() {
  local home id out
  home=$(make_home inj); id=inj-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=gpt-5.6-terra effort=high routing_source=fallback

  out=$(esc "$home" "$id" injection)
  expect_code 0 "$(esc_status)" "injection escalation of a fallback tuple"
  assert_contains "$out" "verdict=relaunch" "injection refusal should relaunch on a new harness"
  assert_tuple "$out" opencode default high
  assert_not_contains "$out" "harness=codex" "injection rotation kept the refusing harness"
  assert_not_contains "$out" "gpt-5.6-terra" "injection rotation carried the refusing harness's local model onto the new one"
  assert_grep "codex,gpt-5.6-terra,high	opencode,default,high" "$home/state/$id.escalation" \
    "escalation log did not record the rotated-and-reset tuple"
  pass "injection refusal rotates codex -> opencode, preserves effort, drops harness-local model"
}

test_injection_rotation_wraps_and_refuses_unverified_current_harness() {
  local home id out
  home=$(make_home inj2); id=inj-wrap-a1
  write_task_meta "$home" "$id" harness=cursor-agent kind=ship model=composer-2 effort=low routing_source=fallback
  out=$(esc "$home" "$id" injection)
  assert_tuple "$out" claude default low
  assert_not_contains "$out" "composer-2" "wrapped rotation carried the refusing harness's local model onto claude"

  id=inj-custom-a1
  write_task_meta "$home" "$id" harness=my-vendor-cli kind=ship model=default effort=low routing_source=fallback
  out=$(esc "$home" "$id" injection)
  assert_contains "$out" "verdict=escalate-captain" "unrotatable harness must escalate to a human"
  assert_contains "$out" "reason=harness-not-rotatable" "unrotatable verdict must name its reason"
  pass "injection rotation wraps cursor-agent -> claude and refuses an unverified current harness"
}

test_injection_rotation_leaves_the_pi_vendor_from_either_identity() {
  local home id out
  home=$(make_home inj-pi)

  id=inj-pi-signed-a1
  write_task_meta "$home" "$id" harness=pi-signed kind=ship model=pi-fast effort=medium routing_source=fallback
  out=$(esc "$home" "$id" injection)
  expect_code 0 "$(esc_status)" "injection escalation of a pi-signed tuple"
  assert_contains "$out" "verdict=relaunch" "a pi-signed refusal must rotate, not go straight to a human"
  assert_not_contains "$out" "reason=harness-not-rotatable" "pi-signed must be a rotatable identity"
  assert_tuple "$out" grok default medium
  assert_not_contains "$out" "harness=pi" "pi-signed rotated onto its own vendor instead of off it"

  id=inj-pi-plain-a1
  write_task_meta "$home" "$id" harness=pi kind=ship model=pi-fast effort=medium routing_source=fallback
  out=$(esc "$home" "$id" injection)
  assert_contains "$out" "verdict=relaunch" "a pi refusal must still rotate"
  assert_tuple "$out" grok default medium
  assert_not_contains "$out" "harness=pi-signed" "pi rotated onto the same vendor's signed identity"
  pass "both Pi identities share one rotation slot: either refusal rotates to grok, never to the other"
}

test_substantive_rung_the_harness_cannot_express_escalates() {
  local home id out
  home=$(make_home effort-axis)

  id=no-effort-flag-a1
  write_task_meta "$home" "$id" harness=opencode kind=ship model=default effort=low routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "an effortless harness resolves cleanly"
  assert_contains "$out" "verdict=escalate-captain" "a rung no adapter flag carries must not relaunch"
  assert_contains "$out" "reason=effort-unsupported" "the effortless verdict must name its reason"
  assert_not_contains "$out" "verdict=relaunch" "an identical relaunch was emitted for an effortless harness"
  assert_tuple "$out" opencode default low

  id=capped-effort-a1
  write_task_meta "$home" "$id" harness=grok kind=ship model=default effort=high routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  assert_contains "$out" "verdict=escalate-captain" "a rung above the adapter's ceiling must not relaunch"
  assert_contains "$out" "reason=effort-capped" "the capped verdict must name its reason"
  assert_tuple "$out" grok default high

  id=within-cap-a1
  write_task_meta "$home" "$id" harness=grok kind=ship model=default effort=low routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  assert_contains "$out" "verdict=relaunch" "a rung the adapter does carry must still relaunch"
  assert_tuple "$out" grok default medium
  pass "substantive rungs stop when the harness would launch identically, and still climb when it would not"
}

test_top_rung_the_harness_never_carried_names_the_axis_truth() {
  local home id out
  home=$(make_home phantom-tier)

  # An injection rotation preserves effort=xhigh onto opencode, whose launch
  # has no effort flag: the top-rung verdict must say the adapter never
  # carried the tier, not that the effort ladder was exhausted.
  id=phantom-effortless-a1
  write_task_meta "$home" "$id" harness=opencode kind=ship model=default effort=xhigh routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "a phantom top rung resolves cleanly"
  assert_contains "$out" "verdict=escalate-captain" "a phantom top rung must still escalate to a human"
  assert_contains "$out" "reason=effort-unsupported" "an effortless adapter's top rung must not claim effort-ceiling"
  assert_not_contains "$out" "reason=effort-ceiling" "effort-ceiling claimed for a tier the launch never carried"
  assert_tuple "$out" opencode default xhigh

  id=phantom-capped-a1
  write_task_meta "$home" "$id" harness=grok kind=ship model=default effort=xhigh routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  assert_contains "$out" "verdict=escalate-captain" "a capped adapter's phantom top rung must still escalate"
  assert_contains "$out" "reason=effort-capped" "a capped adapter's top rung must not claim effort-ceiling"
  assert_tuple "$out" grok default xhigh

  id=real-ceiling-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=xhigh routing_source=fallback
  out=$(esc "$home" "$id" substantive)
  assert_contains "$out" "reason=effort-ceiling" "a tier the adapter verifiably carried must keep effort-ceiling"
  pass "the top-rung verdict names effort-unsupported/effort-capped for tiers the adapter never carried, effort-ceiling only for real ones"
}

test_pinned_or_profiled_tuple_reports_instead_of_escalating() {
  local home id out
  home=$(make_home pinned)

  id=pin-captain-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=gpt-5.6-terra effort=medium routing_source=captain
  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "pinned tuple escalation resolves to a report"
  assert_contains "$out" "verdict=report" "captain-pinned tuple must report, not escalate"
  assert_contains "$out" "reason=routing-pinned" "pinned verdict must name its reason"
  assert_tuple "$out" codex gpt-5.6-terra medium

  id=pin-profile-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low routing_source=profile
  out=$(esc "$home" "$id" substantive)
  assert_contains "$out" "verdict=report" "profile-resolved tuple must report, not escalate"
  assert_contains "$out" "reason=routing-pinned" "profile verdict must name its reason"
  assert_tuple "$out" codex default low
  pass "captain-pinned and profile-resolved tuples report rather than escalating through the pin"
}

test_report_verdict_consumes_budget_and_ends_at_the_captain() {
  local home id out i
  home=$(make_home report-budget); id=report-budget-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low routing_source=profile

  for i in 1 2 3; do
    out=$(esc "$home" "$id" substantive)
    assert_contains "$out" "verdict=report" "pinned escalation $i must still report"
    assert_contains "$out" "reason=routing-pinned" "pinned report $i must name its reason"
    assert_contains "$out" "attempts=$i" "report $i must spend budget slot $i"
    assert_tuple "$out" codex default low
  done

  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "budget exhaustion on the report path resolves cleanly"
  assert_contains "$out" "verdict=escalate-captain" "a task that only ever reports must still reach a human"
  assert_contains "$out" "reason=attempt-budget" "the exhausted report path must name the budget"
  assert_not_contains "$out" "verdict=report" "budget exhaustion must not emit another report"
  assert_tuple "$out" codex default low
  pass "report verdicts spend the same attempt budget, so a pinned task stops relaunching after 3"
}

test_unknown_provenance_reports_also_consume_budget() {
  local home id out i
  home=$(make_home legacy-budget); id=legacy-budget-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low

  for i in 1 2 3; do
    out=$(esc "$home" "$id" mechanical)
    assert_contains "$out" "reason=unknown-provenance" "legacy escalation $i must report unknown provenance"
    assert_contains "$out" "attempts=$i" "legacy report $i must spend budget slot $i"
  done

  out=$(esc "$home" "$id" mechanical)
  assert_contains "$out" "verdict=escalate-captain" "a legacy task must reach a human instead of looping"
  assert_contains "$out" "reason=attempt-budget" "the exhausted legacy path must name the budget"
  pass "unknown-provenance reports spend budget too, so a legacy meta cannot relaunch forever"
}

test_unknown_provenance_reports_fail_closed() {
  local home id out
  home=$(make_home legacy); id=legacy-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low

  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "legacy meta escalation resolves to a report"
  assert_contains "$out" "verdict=report" "unknown provenance must report, not escalate"
  assert_contains "$out" "reason=unknown-provenance" "unknown-provenance verdict must name its reason"
  assert_tuple "$out" codex default low
  pass "a meta without routing_source fails closed: report, never escalate"
}

test_attempt_budget_exhaustion_escalates_to_captain() {
  local home id out i
  home=$(make_home budget); id=budget-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low routing_source=fallback

  for i in 1 2 3; do
    out=$(esc "$home" "$id" mechanical)
    assert_contains "$out" "verdict=relaunch" "mechanical relaunch $i within budget"
    assert_contains "$out" "attempts=$i" "attempt counter after relaunch $i"
  done
  out=$(esc "$home" "$id" mechanical)
  assert_contains "$out" "verdict=escalate-captain" "fourth relaunch request must stop and escalate"
  assert_contains "$out" "reason=attempt-budget" "budget verdict must name its reason"
  assert_not_contains "$out" "verdict=relaunch" "budget exhaustion must not emit another relaunch"
  pass "the ladder stops after 3 relaunches and escalates to a human instead of looping"
}

test_uncountable_relaunch_fails_instead_of_looping() {
  local home id out
  home=$(make_home logfail); id=logfail-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low routing_source=fallback
  mkdir -p "$home/state/$id.escalation"

  out=$(esc "$home" "$id" mechanical)
  expect_code 1 "$(esc_status)" "an unappendable budget log must fail the escalation"
  assert_not_contains "$out" "verdict=relaunch" "a relaunch that consumed no budget slot was emitted anyway"
  assert_absent "$home/state/.$id.escalation.lock" "the escalation lock was not released on the append failure"
  pass "a relaunch the budget log cannot record fails closed instead of relaunching uncounted forever"
}

test_secondmate_and_bad_input_fail_closed() {
  local home id out
  home=$(make_home refuse)

  id=sm-a1
  fm_write_secondmate_meta "$home/state/$id.meta" "$home/sm-home"
  out=$(esc "$home" "$id" substantive)
  expect_code 1 "$(esc_status)" "escalating a secondmate must fail"
  assert_contains "$out" "secondmate" "secondmate refusal must say why"

  id=badclass-a1
  write_task_meta "$home" "$id" harness=codex kind=ship model=default effort=low routing_source=fallback
  out=$(esc "$home" "$id" sideways)
  expect_code 1 "$(esc_status)" "an unknown failure class must fail"
  assert_absent "$home/state/$id.escalation" "a refused class must not write the log"

  out=$(esc "$home" no-such-task substantive)
  expect_code 1 "$(esc_status)" "a missing meta must fail"
  pass "secondmate kind, unknown classes, and missing metadata all fail closed with exit 1"
}

test_relaunch_preserves_account_profile_binding() {
  local home id out
  home=$(make_home account-profile); id=account-profile-a1
  write_task_meta "$home" "$id" harness=claude kind=ship model=default effort=low \
    routing_source=fallback account_profile=paid-primary

  out=$(esc "$home" "$id" substantive)
  expect_code 0 "$(esc_status)" "escalation of an account-bound Claude task"
  assert_contains "$out" "verdict=relaunch" "account-bound task should relaunch"
  assert_contains "$out" "account_profile=paid-primary" \
    "relaunch tuple should preserve the recorded account alias"
  assert_not_contains "$out" "account_profile=paid-secondary" \
    "escalation ladder must not rotate Claude accounts"

  home=$(make_home account-profile-injection); id=account-profile-injection-a1
  write_task_meta "$home" "$id" harness=claude kind=ship model=default effort=low \
    routing_source=fallback account_profile=paid-primary
  out=$(esc "$home" "$id" injection)
  expect_code 0 "$(esc_status)" "injection escalation of an account-bound Claude task"
  assert_contains "$out" "verdict=escalate-captain" \
    "account-bound task must not rotate to a harness that cannot consume the profile"
  assert_contains "$out" "reason=account-profile-harness-bound" \
    "refused account-bound harness rotation should name its reason"
  assert_contains "$out" "harness=claude" "refused account-bound rotation should keep Claude"
  assert_contains "$out" "account_profile=paid-primary" \
    "refused account-bound rotation should preserve the account alias"
  pass "relaunch preserves the recorded Claude account profile binding"
}

test_substantive_failure_raises_default_effort_one_rung
test_substantive_failure_climbs_rungs_then_stops_below_max
test_mechanical_failure_relaunches_same_tuple
test_injection_refusal_rotates_harness_and_preserves_tier
test_injection_rotation_wraps_and_refuses_unverified_current_harness
test_injection_rotation_leaves_the_pi_vendor_from_either_identity
test_substantive_rung_the_harness_cannot_express_escalates
test_top_rung_the_harness_never_carried_names_the_axis_truth
test_pinned_or_profiled_tuple_reports_instead_of_escalating
test_report_verdict_consumes_budget_and_ends_at_the_captain
test_unknown_provenance_reports_fail_closed
test_unknown_provenance_reports_also_consume_budget
test_attempt_budget_exhaustion_escalates_to_captain
test_uncountable_relaunch_fails_instead_of_looping
test_secondmate_and_bad_input_fail_closed
test_relaunch_preserves_account_profile_binding
