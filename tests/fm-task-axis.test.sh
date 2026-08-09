#!/usr/bin/env bash
# Behavior tests for the three task-identity axes (AGENTS.md section 2; the
# `kind` row of docs/vocabulary-collisions.md).
#
# One `kind=` field used to carry role, deliverable type, and lifecycle stage at
# once. These cases pin the migration contract that replaced it: every writer
# dual-writes the axes beside the deprecated alias, a record predating the split
# derives its axes deterministically, the backfill converges old records without
# rewriting anything it already agrees with, and a record whose alias and axes
# disagree is REFUSED everywhere rather than silently resolved.
#
# The refusal cases are the point of the suite. A stale writer that flips the old
# field alone is exactly the failure a dual-write window invites, and a fleet that
# quietly picked one side would decide a task's identity - which teardown
# protection applies to its work - by luck.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REFLAG="$ROOT/bin/fm-reflag.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-axis)

# Read the axes through the library the fleet actually uses, in a subshell so a
# sourced library never leaks into the next case. Prints "<role> <deliverable> <stage>".
axes_of() {  # <meta>
  (
    # shellcheck source=bin/fm-backend.sh disable=SC1091
    . "$ROOT/bin/fm-backend.sh"
    # shellcheck source=bin/fm-task-axis-lib.sh disable=SC1091
    . "$ROOT/bin/fm-task-axis-lib.sh"
    printf '%s %s %s\n' "$(fm_task_role "$1")" "$(fm_task_deliverable "$1")" "$(fm_task_stage "$1")"
  )
}

# Run one axis-library function against a meta and report its exit status.
axis_call() {  # <fn> <args>...
  (
    # shellcheck source=bin/fm-backend.sh disable=SC1091
    . "$ROOT/bin/fm-backend.sh"
    # shellcheck source=bin/fm-task-axis-lib.sh disable=SC1091
    . "$ROOT/bin/fm-task-axis-lib.sh"
    "$@"
  )
}

# Does <meta> still parse as PR identity? Read through the real owner
# (bin/fm-pr-lib.sh), never a local re-implementation of its rule.
pr_identity_valid() {  # <meta>
  (
    # shellcheck source=bin/fm-backend.sh disable=SC1091
    . "$ROOT/bin/fm-backend.sh"
    # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
    . "$ROOT/bin/fm-pr-lib.sh"
    fm_pr_metadata_identity_parse "$1"
  ) >/dev/null 2>&1
}

# Every value the retired field ever took derives to exactly one point on each
# axis. This table IS the migration contract, so it is asserted directly rather
# than inferred from a consumer's behavior.
test_derivation_is_total_and_deterministic() {
  local dir meta got
  dir="$TMP_ROOT/derive"
  mkdir -p "$dir"

  set -- "scout:crew scout commissioned" \
         "ship:crew ship commissioned" \
         "secondmate:secondmate ship commissioned"
  for entry in "$@"; do
    meta="$dir/${entry%%:*}.meta"
    fm_write_meta "$meta" "window=w" "kind=${entry%%:*}" "worktree=/tmp/wt"
    got=$(axes_of "$meta")
    [ "$got" = "${entry#*:}" ] \
      || fail "kind=${entry%%:*} derived '$got', expected '${entry#*:}'"
  done

  # A record with no alias at all is the spawn default rather than an error: the
  # consumers this replaced all defaulted an absent kind= the same way.
  fm_write_meta "$dir/bare.meta" "window=w" "worktree=/tmp/wt"
  got=$(axes_of "$dir/bare.meta")
  [ "$got" = "crew ship commissioned" ] || fail "a record with no alias derived '$got'"

  # An explicit axis always wins over the alias's derivation - that is what makes
  # a reflagged task readable at all, since its alias cannot express the stage.
  fm_write_meta "$dir/explicit.meta" "kind=ship" "role=crew" "deliverable=ship" "stage=reflagged"
  got=$(axes_of "$dir/explicit.meta")
  [ "$got" = "crew ship reflagged" ] || fail "explicit axes did not win: '$got'"

  pass "task axes: derivation from the deprecated alias is total and deterministic"
}

# Backfill must converge an old record and then leave it alone. A sweep that
# rewrote on every pass would churn durable state on every session start.
test_backfill_is_deterministic_and_idempotent() {
  local dir meta first second third
  dir="$TMP_ROOT/backfill"
  mkdir -p "$dir"
  meta="$dir/old.meta"
  fm_write_meta "$meta" "window=w" "kind=scout" "worktree=/tmp/wt"

  axis_call fm_task_axes_backfill "$meta" || fail "backfill refused a plain pre-split record"
  first=$(cat "$meta")
  assert_grep 'role=crew' "$meta" "backfill did not derive the role axis"
  assert_grep 'deliverable=scout' "$meta" "backfill did not derive the deliverable axis"
  assert_grep 'stage=commissioned' "$meta" "backfill did not record the spawn stage"
  assert_grep 'kind=scout' "$meta" "backfill rewrote the deprecated alias instead of leaving it"
  assert_grep 'worktree=/tmp/wt' "$meta" "backfill disturbed an unrelated field"

  axis_call fm_task_axes_backfill "$meta" || fail "a second backfill refused a converged record"
  second=$(cat "$meta")
  [ "$first" = "$second" ] || fail "backfill was not idempotent:"$'\n'"--- first ---"$'\n$first'$'\n'"--- second ---"$'\n'"$second"

  # Deterministic across records, not merely stable within one: the same input
  # must produce the same axes in a different home.
  fm_write_meta "$dir/twin.meta" "window=w" "kind=scout" "worktree=/tmp/wt"
  axis_call fm_task_axes_backfill "$dir/twin.meta" || fail "backfill refused the twin record"
  third=$(cat "$dir/twin.meta")
  [ "$first" = "$third" ] || fail "backfill was not deterministic across identical records"

  # A record that already states a partial set keeps what it states and gains
  # only what is missing.
  fm_write_meta "$dir/partial.meta" "kind=ship" "stage=reflagged"
  axis_call fm_task_axes_backfill "$dir/partial.meta" || fail "backfill refused a partial record"
  assert_grep 'stage=reflagged' "$dir/partial.meta" "backfill overwrote a stage the record already stated"
  assert_grep 'role=crew' "$dir/partial.meta" "backfill did not fill the missing role axis"
  [ "$(grep -c '^stage=' "$dir/partial.meta")" = 1 ] || fail "backfill left a duplicate stage line"

  pass "task axes: backfill is deterministic, forward-only, and idempotent"
}

# A task's record doubles as PR identity, and bin/fm-pr-lib.sh refuses any
# unrecognized key appearing AFTER `pr=` - that rule is what stops a tampered
# record from smuggling a second identity past an armed merge poll. Backfill
# therefore may not simply append: a record with a live poll must still parse, or
# the watcher silently stops honoring that task's merge watch.
test_backfill_preserves_pr_identity() {
  local dir meta sha
  dir="$TMP_ROOT/pr-identity"
  mkdir -p "$dir"
  meta="$dir/polled.meta"
  sha=$(printf '%040d' 1 | tr '0' 'a')
  fm_write_meta "$meta" "window=fm-polled" "kind=ship" \
    "pr=https://github.com/o/r/pull/13" "pr_head=$sha"

  # Negative control: the identity must parse BEFORE the backfill, so a failure
  # afterwards is the backfill and not an unparseable fixture.
  pr_identity_valid "$meta" || fail "the fixture did not parse as PR identity before backfill"

  axis_call fm_task_axes_backfill "$meta" || fail "backfill refused a record carrying a PR"
  pr_identity_valid "$meta" || fail "backfill invalidated the record's PR identity"

  assert_grep 'role=crew' "$meta" "backfill did not derive the axes on a polled record"
  # Position is the contract, not tidiness: every axis must precede the pr line.
  [ "$(grep -n 'stage=' "$meta" | cut -d: -f1)" -lt "$(grep -n '^pr=' "$meta" | cut -d: -f1)" ] \
    || fail "backfill wrote an axis after pr=, which invalidates the record"

  pass "task axes: backfill keeps a polled record's PR identity parseable"
}

# The stale-writer guard. A writer that still flips only the retired field
# desynchronizes a task's identity, and every consumer must refuse that record
# rather than choose a side.
test_conflicted_records_are_refused_not_resolved() {
  local dir meta out status
  dir="$TMP_ROOT/conflict"
  mkdir -p "$dir"

  # Negative control: the identical assertion must pass a consistent record, so a
  # refusal below is the conflict and not a broken check.
  fm_write_meta "$dir/agree.meta" "kind=ship" "role=crew" "deliverable=ship" "stage=commissioned"
  axis_call fm_task_axes_conflict "$dir/agree.meta" \
    && fail "a consistent record was reported as conflicted"
  axis_call fm_task_axes_backfill "$dir/agree.meta" \
    || fail "backfill refused a consistent record"

  # The exact stale-writer shape: the old field was flipped to ship, the
  # deliverable axis still says scout.
  meta="$dir/stale.meta"
  fm_write_meta "$meta" "window=w" "kind=ship" "role=crew" "deliverable=scout" "stage=commissioned" "worktree=/tmp/wt"
  axis_call fm_task_axes_conflict "$meta" || fail "the stale-writer record was not detected as conflicted"

  out=$(axis_call fm_task_axes_backfill "$meta" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "backfill converged a conflicted record instead of refusing it"
  assert_contains "$out" "deliverable=scout" "the backfill refusal did not name the disagreement"

  # A role-axis disagreement is caught the same way.
  fm_write_meta "$dir/role.meta" "kind=ship" "role=secondmate"
  axis_call fm_task_axes_conflict "$dir/role.meta" || fail "a role-axis disagreement was not detected"

  pass "task axes: a record whose alias contradicts its axes is refused, not resolved"
}

# The bootstrap sweep is where an existing home converges. It must report the
# refusal loudly and still leave the unaffected records converged.
test_bootstrap_sweep_converges_and_reports_conflicts() {
  local home out
  home="$TMP_ROOT/sweep/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  fm_write_meta "$home/state/good.meta" "window=w" "kind=scout" "worktree=/tmp/wt"
  fm_write_meta "$home/state/bad.meta" "window=w" "kind=ship" "deliverable=scout"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-bootstrap.sh" 2>&1 || true)

  assert_contains "$out" "TASK_AXIS_BACKFILL:" "the sweep did not report the contradictory record"
  assert_contains "$out" "bad" "the sweep did not name the contradictory task"
  assert_grep 'deliverable=scout' "$home/state/good.meta" "the sweep did not converge the sound record"
  assert_no_grep 'role=' "$home/state/bad.meta" "the sweep wrote axes into the record it refused"

  pass "task axes: the startup sweep converges sound records and refuses contradictory ones"
}

# Dual-write is what makes the migration safe, so the reflag writer must emit
# both the axes and the alias, and must move the stage axis - the fact the old
# field could never express.
test_reflag_writes_the_axes_and_moves_the_stage() {
  local home meta out status
  home="$TMP_ROOT/reflag/home"
  mkdir -p "$home/state"
  meta="$home/state/axis-r1.meta"
  fm_write_meta "$meta" "window=fm-axis-r1" "kind=scout" "worktree=/tmp/wt"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" axis-r1 --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "reflagging a scout with both flags should succeed"$'\n'"$out"

  assert_grep 'deliverable=ship' "$meta" "reflag did not move the deliverable axis"
  assert_grep 'stage=reflagged' "$meta" "reflag did not move the stage axis"
  assert_grep 'role=crew' "$meta" "reflag did not preserve the role axis"
  assert_grep 'kind=ship' "$meta" "reflag did not dual-write the deprecated alias"
  [ "$(grep -c '^stage=' "$meta")" = 1 ] || fail "reflag left more than one stage line"
  [ "$(grep -c '^deliverable=' "$meta")" = 1 ] || fail "reflag left more than one deliverable line"

  # The written record must read back consistently through the library, which is
  # the property that keeps every downstream consumer correct.
  [ "$(axes_of "$meta")" = "crew ship reflagged" ] \
    || fail "the reflagged record does not read back as a reflagged ship: $(axes_of "$meta")"

  # Reflagging is scout-to-ship only, and after the move the same task is no
  # longer a scout - so a second reflag is refused on the deliverable axis.
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" axis-r1 --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reflagging an already-shipped task should be refused"
  assert_contains "$out" "not a scout task" "the second reflag refusal did not name the deliverable"

  pass "fm-reflag: the scout-to-ship move writes every axis and advances the stage"
}

# Reflagging decides a task's delivery contract, so it must refuse a record whose
# identity nobody can read rather than deciding that identity by luck.
test_reflag_refuses_a_contradictory_record() {
  local home meta out status before
  home="$TMP_ROOT/reflag-conflict/home"
  mkdir -p "$home/state"
  meta="$home/state/axis-r2.meta"
  fm_write_meta "$meta" "window=fm-axis-r2" "kind=scout" "deliverable=ship" "worktree=/tmp/wt"
  before=$(cat "$meta")

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$REFLAG" axis-r2 --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "reflagging a contradictory record should exit non-zero"
  assert_contains "$out" "contradictory identity" "the reflag refusal did not name the contradiction"
  [ "$(cat "$meta")" = "$before" ] || fail "the refused reflag still changed the task record"

  pass "fm-reflag: a task whose alias contradicts its axes is refused before any write"
}

# The old entry point is a bounded shim, not an alias: it must forward, say so,
# and leave the evidence that settles its own retirement.
test_the_retired_entry_point_forwards_and_records_its_use() {
  local home meta out status
  home="$TMP_ROOT/shim/home"
  mkdir -p "$home/state"
  meta="$home/state/axis-s1.meta"
  fm_write_meta "$meta" "window=fm-axis-s1" "kind=scout" "worktree=/tmp/wt"

  assert_absent "$home/state/.reflag-shim-used" "the shim marker existed before the shim ran"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" axis-s1 --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "the compatibility shim should still complete the move"$'\n'"$out"
  assert_contains "$out" "compatibility shim" "the shim did not warn that the old name is retiring"
  assert_contains "$out" "fm-reflag.sh" "the shim warning did not name its replacement"
  assert_grep 'stage=reflagged' "$meta" "the shim did not forward to the real operation"
  assert_present "$home/state/.reflag-shim-used" "the shim left no evidence for its own retirement"

  pass "fm-promote: the retired entry point forwards, warns, and records its own use"
}

# Teardown protection is the highest-consequence consumer of a task's identity,
# so a contradictory record must stop it rather than let it pick a protection.
test_teardown_refuses_a_contradictory_identity() {
  local home meta out status
  home="$TMP_ROOT/teardown/home"
  mkdir -p "$home/state" "$home/data" "$home/config"
  meta="$home/state/axis-t1.meta"
  mkdir -p "$TMP_ROOT/teardown/wt" "$TMP_ROOT/teardown/proj"
  # A complete endpoint record, so this case reaches the identity check rather
  # than stopping at teardown's earlier endpoint validation.
  fm_write_meta "$meta" \
    "window=firstmate:fm-axis-t1" \
    "endpoint_task_id=axis-t1" \
    "worktree=$TMP_ROOT/teardown/wt" \
    "project=$TMP_ROOT/teardown/proj" \
    "kind=scout" \
    "deliverable=ship"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" axis-t1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "teardown of a contradictory record should exit non-zero"
  assert_contains "$out" "contradictory identity" "the teardown refusal did not name the contradiction"
  assert_present "$meta" "the refused teardown still removed the task record"

  pass "fm-teardown: a task whose alias contradicts its axes is refused before any cleanup"
}

test_derivation_is_total_and_deterministic
test_backfill_is_deterministic_and_idempotent
test_backfill_preserves_pr_identity
test_conflicted_records_are_refused_not_resolved
test_bootstrap_sweep_converges_and_reports_conflicts
test_reflag_writes_the_axes_and_moves_the_stage
test_reflag_refuses_a_contradictory_record
test_the_retired_entry_point_forwards_and_records_its_use
test_teardown_refuses_a_contradictory_identity
