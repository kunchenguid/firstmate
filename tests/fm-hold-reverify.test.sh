#!/usr/bin/env bash
# Behavior tests for bin/fm-hold-reverify.sh, the recurring re-verification of
# aged captain-held backlog tasks.
#
# Every case drives the executable interface: it builds a fixture home whose
# data/backlog.md holds aged captain rows with a known ground truth, fakes the
# forge (a PATH `gh` answering `api graphql` from a per-home state file) so no
# case ever contacts a network, and runs the real `check`/`classify`/`arm`/
# `disarm` commands. Assertions read the resulting docket and the printed wake
# line, never any implementation source byte, so a rewrite that keeps the
# behavior passes.
#
# The ground truths the classifier must separate:
#   a merged pull request            -> dead
#   a still-open question (open PR)  -> still_live
#   a superseded/closed finding      -> not_a_decision
#   no readable subject              -> unestablishable
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-hold-reverify.sh"
TMP_ROOT=$(fm_test_tmproot fm-hold-reverify)
FIXED_NOW=2026-09-20T00:00:00Z
OLD_HOLD_SET=2026-01-01T00:00:00Z
YOUNG_HOLD_SET=2026-09-19T00:00:00Z

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# make_home <name>: a scratch home with an empty backlog and a forge fake.
make_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/forge"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fakebin="$home/fakebin"
  # A fake forge: the state of pull request <n> is read from $FM_TEST_FORGE_DIR/<n>
  # as two fields "<STATE> <merged>". A first field of FAIL makes the read fail,
  # standing in for an unauthenticated or unreachable forge. Applied only when
  # invoked as `gh api graphql -F number=<n>`.
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "api graphql")
    number= prev=
    for arg in "$@"; do
      if [ "$prev" = "-F" ]; then
        case "$arg" in number=*) number=${arg#number=} ;; esac
      fi
      prev=$arg
    done
    [ -n "$number" ] || exit 1
    fixture="${FM_TEST_FORGE_DIR:-}/$number"
    [ -f "$fixture" ] || exit 1
    read -r pr_state merged < "$fixture"
    [ "$pr_state" != FAIL ] || exit 1
    printf 'state=%s\nmerged=%s\n' "$pr_state" "$merged"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/gh"
  printf '%s\n' "$home"
}

# write_backlog <home>: the whole backlog comes from stdin, so a case can name
# exactly the rows and ground truth it needs.
write_backlog() {
  local home=$1
  cat > "$home/data/backlog.md"
}

# set_pr <home> <number> <STATE> <merged>: the faked forge answer for one PR.
set_pr() {
  local home=$1 number=$2 state=$3 merged=$4
  printf '%s %s\n' "$state" "$merged" > "$home/forge/$number"
}

# run_check <home> <out-file> [extra env KEY=VAL...]: run one sweep with a pinned
# snapshot clock, no cadence gate, and the fixture forge.
run_check() {
  local home=$1 out=$2 status=0
  shift 2
  env FM_CHECK_TIMEOUT=30 \
    FM_SNAPSHOT_NOW="$FIXED_NOW" \
    FM_HOLD_REVERIFY_INTERVAL=0 \
    FM_TEST_FORGE_DIR="$home/forge" \
    FM_HOME="$home" \
    PATH="$home/fakebin:$PATH" \
    "$@" "$CHECK" check >"$out" 2>&1 || status=$?
  printf '%s\n' "$status"
}

# docket_verdict <home> <id>: the verdict recorded for one hold.
docket_verdict() {
  jq -r --arg id "$2" '.findings[] | select(.id == $id) | .verdict' \
    "$1/state/hold-reverify/docket.json" 2>/dev/null
}

# --- classifier: four ground truths -----------------------------------------

test_merged_pull_request_reports_dead() {
  local home out
  home=$(make_home merged)
  set_pr "$home" 101 MERGED true
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-merged - Ship the thing https://github.com/o/r/pull/101 (repo: sample) (kind: captain) (since 2026-01-01) (hold: approve the thing) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "merged sweep exit"
  assert_equals dead "$(docket_verdict "$home" h-merged)" \
    "a merged pull request is shipped reality, so the hold reports dead"
  assert_contains "$(cat "$out")" "1 dead" "the wake line counts the dead finding"
  pass "fm-hold-reverify: a merged pull request reports dead"
}

test_open_question_reports_still_live() {
  local home out
  home=$(make_home open)
  set_pr "$home" 102 OPEN false
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-open - Decide the other thing https://github.com/o/r/pull/102 (repo: sample) (kind: captain) (since 2026-01-01) (hold: decide the other) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "open sweep exit"
  assert_equals still_live "$(docket_verdict "$home" h-open)" \
    "an open pull request is a still-open question"
  assert_contains "$(cat "$out")" "1 still live" "the wake line counts the live finding"
  pass "fm-hold-reverify: an open question reports still_live"
}

test_superseded_finding_reports_not_a_decision() {
  local home out
  home=$(make_home superseded)
  # The finding this call asked about has since been superseded and the call is
  # closed, but the row still carries the captain hold annotation: it is not a
  # live decision. A questionless annotated row is the same shape.
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-ghost - A question with no decision recorded (repo: sample) (kind: captain) (since 2026-01-01) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done

- [x] h-closed - Superseded by later work (repo: sample) (kind: captain) (merged 2026-02-01) (since 2026-01-01) (hold: old call) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "superseded sweep exit"
  assert_equals not_a_decision "$(docket_verdict "$home" h-ghost)" \
    "an annotated row with no question is not a live decision"
  assert_equals not_a_decision "$(docket_verdict "$home" h-closed)" \
    "a closed call still carrying the annotation is not a live decision"
  assert_contains "$(cat "$out")" "2 not-a-decision" "the wake line counts both ghosts"
  pass "fm-hold-reverify: a superseded or closed finding reports not_a_decision"
}

test_no_subject_and_unreadable_forge_are_unestablishable() {
  local home out
  home=$(make_home unest)
  set_pr "$home" 103 FAIL false
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-nosubject - A question with no artifact named (repo: sample) (kind: captain) (since 2026-01-01) (hold: pick an approach) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET
- [ ] h-unreadable - A question whose PR cannot be read https://github.com/o/r/pull/103 (repo: sample) (kind: captain) (since 2026-01-01) (hold: check the PR) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "unestablishable sweep exit"
  assert_equals unestablishable "$(docket_verdict "$home" h-nosubject)" \
    "a hold naming no structured subject cannot be re-checked"
  assert_equals unestablishable "$(docket_verdict "$home" h-unreadable)" \
    "an unreadable forge is unestablishable, never dead"
  pass "fm-hold-reverify: no subject and an unreadable forge are unestablishable"
}

test_closed_unmerged_is_unestablishable_never_dead() {
  local home out
  home=$(make_home closedunmerged)
  set_pr "$home" 104 CLOSED false
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-closedpr - A question whose PR closed unmerged https://github.com/o/r/pull/104 (repo: sample) (kind: captain) (since 2026-01-01) (hold: check it) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "closed-unmerged sweep exit"
  assert_equals unestablishable "$(docket_verdict "$home" h-closedpr)" \
    "a closed-unmerged PR is ambiguous and must never be reported dead"
  pass "fm-hold-reverify: a closed-unmerged PR is unestablishable"
}

test_young_hold_is_not_examined() {
  local home out
  home=$(make_home young)
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-young - A fresh question (repo: sample) (kind: captain) (since 2026-09-19) (hold: fresh) (hold-kind: captain)
  Captain hold set: $YOUNG_HOLD_SET

## Done
EOF
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out")" "young sweep exit"
  [ ! -s "$out" ] || fail "a hold younger than the age threshold must not produce a finding: $(cat "$out")"
  jq -e '.examined == 0' "$home/state/hold-reverify/docket.json" >/dev/null \
    || fail "a young hold must not be examined"
  pass "fm-hold-reverify: a hold younger than the threshold is ignored"
}

# --- reporting contract ------------------------------------------------------

test_repeat_is_silent_and_change_wakes() {
  local home out status
  home=$(make_home repeat)
  set_pr "$home" 105 MERGED true
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-repeat - Ship it https://github.com/o/r/pull/105 (repo: sample) (kind: captain) (since 2026-01-01) (hold: approve) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  status=$(run_check "$home" "$out")
  expect_code 0 "$status" "first sweep exit"
  assert_contains "$(cat "$out")" "1 dead" "the first sweep names the new finding"

  # Same ground truth, new sweep: the finding set is unchanged, so silence.
  : > "$out"
  status=$(run_check "$home" "$out")
  expect_code 0 "$status" "repeat sweep exit"
  [ ! -s "$out" ] || fail "an unchanged finding set must stay silent: $(cat "$out")"

  # The subject opens again: a changed verdict is news.
  set_pr "$home" 105 OPEN false
  : > "$out"
  status=$(run_check "$home" "$out")
  expect_code 0 "$status" "changed sweep exit"
  assert_contains "$(cat "$out")" "1 still live" "a changed verdict wakes once"
  pass "fm-hold-reverify: an unchanged sweep is silent and a changed verdict wakes"
}

test_cadence_gate_suppresses_until_the_interval_elapses() {
  local home out status
  home=$(make_home cadence)
  set_pr "$home" 106 MERGED true
  write_backlog "$home" <<EOF
## In flight

## Queued

- [ ] h-cad - Ship it https://github.com/o/r/pull/106 (repo: sample) (kind: captain) (since 2026-01-01) (hold: approve) (hold-kind: captain)
  Captain hold set: $OLD_HOLD_SET

## Done
EOF
  out="$home/out"
  status=$(run_check "$home" "$out" FM_HOLD_REVERIFY_INTERVAL=21600)
  expect_code 0 "$status" "cadence first sweep exit"
  assert_contains "$(cat "$out")" "1 dead" "the first sweep reports the dead finding"

  # The subject opens, which would change the verdict, but a sweep inside the
  # interval must still be silent: this is the gate, not the digest.
  set_pr "$home" 106 OPEN false
  : > "$out"
  status=$(run_check "$home" "$out" FM_HOLD_REVERIFY_INTERVAL=21600)
  expect_code 0 "$status" "cadence immediate sweep exit"
  [ ! -s "$out" ] || fail "a sweep inside the cadence interval must stay silent: $(cat "$out")"

  # Past the interval the gate opens and the changed finding is reported.
  : > "$out"
  status=$(run_check "$home" "$out" FM_HOLD_REVERIFY_INTERVAL=21600 \
    FM_HOLD_REVERIFY_NOW=$(( $(date +%s) + 1000000 )))
  expect_code 0 "$status" "cadence advanced sweep exit"
  assert_contains "$(cat "$out")" "1 still live" "past the interval the changed finding wakes"
  pass "fm-hold-reverify: the cadence gate suppresses sweeps until the interval elapses"
}

test_sweep_defers_beyond_the_hold_cap() {
  local home out i
  home=$(make_home cap)
  {
    printf '## In flight\n\n## Queued\n\n'
    for i in 1 2 3; do
      printf -- '- [ ] h-cap%s - A question with no artifact (repo: sample) (kind: captain) (since 2026-01-01) (hold: pick) (hold-kind: captain)\n  Captain hold set: %s\n' "$i" "$OLD_HOLD_SET"
    done
    printf '\n## Done\n'
  } > "$home/data/backlog.md"
  out="$home/out"
  expect_code 0 "$(run_check "$home" "$out" FM_HOLD_REVERIFY_MAX_HOLDS=2)" "capped sweep exit"
  assert_equals 2 "$(jq -r '.examined' "$home/state/hold-reverify/docket.json")" \
    "the sweep examines no more than the cap"
  assert_equals 1 "$(jq -r '.deferred' "$home/state/hold-reverify/docket.json")" \
    "the remainder is recorded as deferred, not silently dropped"
  assert_contains "$(cat "$out")" "1 deferred" "the wake line discloses the deferred remainder"
  pass "fm-hold-reverify: the hold cap bounds the sweep and discloses what it deferred"
}

test_unreadable_projection_reports_once() {
  local home out broken status
  home=$(make_home broken)
  broken="$home/broken-snapshot.sh"
  cat > "$broken" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$broken"
  out="$home/out"
  status=$(run_check "$home" "$out" FM_HOLD_REVERIFY_SNAPSHOT_BIN="$broken")
  expect_code 0 "$status" "broken projection sweep exit"
  assert_contains "$(cat "$out")" "could not read the aged-hold projection" \
    "an unreadable projection is reported rather than silently passing"

  : > "$out"
  run_check "$home" "$out" FM_HOLD_REVERIFY_SNAPSHOT_BIN="$broken" >/dev/null
  [ ! -s "$out" ] || fail "the same projection failure must not repeat every sweep: $(cat "$out")"
  pass "fm-hold-reverify: an unreadable projection is reported once"
}

# --- classify seam -----------------------------------------------------------

test_classify_prints_the_verdict_for_facts() {
  local home facts
  home=$(make_home classify)
  facts="$home/facts.json"

  printf '%s\n' '{"state":"queued","hold_reason":"q","pr_state":"merged","completion_merged":false}' > "$facts"
  assert_equals dead "$("$CHECK" classify "$facts")" "merged facts classify dead"

  printf '%s\n' '{"state":"queued","hold_reason":"q","pr_state":"open","completion_merged":false}' > "$facts"
  assert_equals still_live "$("$CHECK" classify "$facts")" "open facts classify still_live"

  printf '%s\n' '{"state":"queued","hold_reason":"","pr_state":"none","completion_merged":false}' > "$facts"
  assert_equals not_a_decision "$("$CHECK" classify "$facts")" "a questionless record is not a decision"

  printf '%s\n' '{"state":"done","hold_reason":"q","pr_state":"none","completion_merged":false}' > "$facts"
  assert_equals not_a_decision "$("$CHECK" classify "$facts")" "a closed record is not a live decision"

  printf '%s\n' '{"state":"queued","hold_reason":"q","pr_state":"closed","completion_merged":true}' > "$facts"
  assert_equals dead "$("$CHECK" classify "$facts")" "a recorded merged completion is dead"

  printf '%s\n' '{"state":"queued","hold_reason":"q","pr_state":"none","completion_merged":false}' > "$facts"
  assert_equals unestablishable "$("$CHECK" classify "$facts")" "facts with no evidence are unestablishable"
  pass "fm-hold-reverify: classify reports the right verdict for each fact shape"
}

# --- arming ------------------------------------------------------------------

test_arm_writes_and_registers_and_disarm_removes() {
  local home status
  home=$(make_home arm)
  status=0
  FM_HOME="$home" FM_HOLD_REVERIFY_AGE_DAYS=14 "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/hold-reverify.check.sh" "arm writes the check shim"
  assert_present "$home/state/hold-reverify.check-trust" "arm binds the shim bytes"
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" hold-reverify
  ' _ "$ROOT" "$home/state" || fail "arm must register the shim with a matching trust binding"

  status=0
  FM_HOME="$home" "$CHECK" disarm >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "disarm exit"
  assert_absent "$home/state/hold-reverify.check.sh" "disarm removes the check shim"
  assert_absent "$home/state/hold-reverify.check-trust" "disarm removes the trust binding"
  pass "fm-hold-reverify: arm writes and binds the standing check and disarm removes it"
}

test_help_and_usage() {
  local status=0
  "$CHECK" --help >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "help exit"
  status=0
  "$CHECK" bogus >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "unknown command exit"
  pass "fm-hold-reverify: help prints and an unknown command is refused"
}

test_merged_pull_request_reports_dead
test_open_question_reports_still_live
test_superseded_finding_reports_not_a_decision
test_no_subject_and_unreadable_forge_are_unestablishable
test_closed_unmerged_is_unestablishable_never_dead
test_young_hold_is_not_examined
test_repeat_is_silent_and_change_wakes
test_cadence_gate_suppresses_until_the_interval_elapses
test_sweep_defers_beyond_the_hold_cap
test_unreadable_projection_reports_once
test_classify_prints_the_verdict_for_facts
test_arm_writes_and_registers_and_disarm_removes
test_help_and_usage
