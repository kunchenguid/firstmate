#!/usr/bin/env bash
# Behavioral regressions for the worker-initiated validation transition.
#
# The implementation-committed -> validate step used to be actuated by firstmate
# typing the validation trigger into a worker's composer after the worker
# appended `done:` and stopped. That actuator had a measured false-positive
# class (2026-07-03: text left fully typed but unsubmitted while the send
# reported success) and spent a firstmate turn on a transition the worker had
# already earned. It is retired: the generated no-mistakes definition of done
# now has the worker start its own run with one blocking call.
#
# Each absence assertion below is paired with a negative control that
# reconstructs the retired shape and watches the same predicate go red, because
# a check that can only report "not found" cannot tell a passing brief from a
# broken generator.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIEF="$ROOT/bin/fm-brief.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-initiated-validation)

# The retired handoff sentence, restored verbatim by the negative controls.
RETIRED_HANDOFF='Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.'

scaffold_no_mistakes_brief() {  # <id> -> echoes brief path
  local id=$1 home="$TMP_ROOT/$1"
  mkdir -p "$home/data"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$BRIEF" "$id" sampleproj --mode no-mistakes >/dev/null 2>&1 \
    || fail "fm-brief.sh refused to scaffold a no-mistakes brief for $id"
  printf '%s\n' "$home/data/$id/brief.md"
}

# --- predicates under test --------------------------------------------------
#
# Written as 0/1 predicates rather than assertions so a negative control can
# invoke the identical check against a deliberately broken brief and observe it
# fail, instead of the check merely never firing.

# The worker is told to start the run itself, with the intent flag the pipeline
# requires to begin one.
brief_starts_its_own_run() {  # <brief>
  grep -qF 'no-mistakes axi run --intent' "$1"
}

# The retired shape: stop after the implementation commit and be restarted from
# outside. Either half is the defect.
brief_hands_the_transition_back() {  # <brief>
  grep -qF 'instruct you to run' "$1" || grep -qF '/no-mistakes' "$1"
}

# The shared daemon serves every lane at once, so a worker must never restart it.
brief_preserves_shared_daemon_rule() {  # <brief>
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal Markdown in the generated brief, not expansions.
  grep -qF 'Never stop, restart, or update the shared `no-mistakes` daemon' "$1" \
    && grep -qF 'only firstmate manages the daemon' "$1"
}

# A run belongs to the branch it names. A worker that starts its own run can now
# reach a foreign lane's run through the tooling's cross-branch fallback, so the
# contract has to refuse it rather than drive it.
brief_refuses_a_foreign_branch_run() {  # <brief>
  grep -qF 'validates YOUR branch only' "$1" \
    && grep -qF 'another lane' "$1" \
    && grep -qF 'never respond to it, abort it, or adopt it as your own' "$1"
}

test_worker_starts_the_run_without_a_firstmate_turn() {
  local brief control
  brief=$(scaffold_no_mistakes_brief starts-own-run)

  brief_starts_its_own_run "$brief" \
    || fail "no-mistakes brief does not tell the worker to start its own run"
  assert_grep 'do not wait to be told' "$brief" \
    "no-mistakes brief left the worker waiting to be restarted"
  assert_grep 'Do not append a status line for the commit' "$brief" \
    "no-mistakes brief still wakes firstmate between the commit and the run"
  ! brief_hands_the_transition_back "$brief" \
    || fail "no-mistakes brief still hands the validate transition back to firstmate"

  # Negative control: restore the retired handoff and watch both predicates
  # reverse. Without this, "no handoff found" is indistinguishable from a
  # generator that emitted nothing at all.
  control="$TMP_ROOT/restored-handoff.md"
  sed 's|^Start it directly\..*|'"$RETIRED_HANDOFF"'|' "$brief" > "$control"
  sed -i 's|`no-mistakes axi run --intent .*|Firstmate will send the trigger.|' "$control"
  brief_hands_the_transition_back "$control" \
    || fail "negative control did not go red: the handoff check cannot detect a restored handoff"
  ! brief_starts_its_own_run "$control" \
    || fail "negative control did not go red: the run-start check cannot detect a missing run start"

  pass "a no-mistakes worker starts validation itself, with no firstmate turn between commit and run"
}

test_shared_daemon_rule_is_preserved() {
  local brief control
  brief=$(scaffold_no_mistakes_brief daemon-rule)

  brief_preserves_shared_daemon_rule "$brief" \
    || fail "no-mistakes brief lost the shared-daemon prohibition"
  assert_grep 'never restart the daemon to clear it' "$brief" \
    "definition of done does not reinforce the daemon rule where a worker now meets a foreign run"

  control="$TMP_ROOT/daemon-rule-dropped.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal Markdown in the generated brief, not expansions.
  grep -vF 'Never stop, restart, or update the shared `no-mistakes` daemon' "$brief" > "$control"
  ! brief_preserves_shared_daemon_rule "$control" \
    || fail "negative control did not go red: the daemon-rule check passes a brief that lost the rule"

  pass "worker-started validation preserves the one-instance shared-daemon rule"
}

test_a_foreign_branch_run_is_refused_not_joined() {
  local brief control
  brief=$(scaffold_no_mistakes_brief foreign-run)

  brief_refuses_a_foreign_branch_run "$brief" \
    || fail "no-mistakes brief lets a worker adopt a run belonging to another branch"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal Markdown in the generated brief, not expansions.
  assert_grep 'Check the `branch:` of any run you are shown' "$brief" \
    "no-mistakes brief does not have the worker check a run's branch before claiming it"

  control="$TMP_ROOT/foreign-run-joined.md"
  # shellcheck disable=SC2016 # single quotes are deliberate: the backticks are literal Markdown in the generated brief, not expansions.
  sed 's|^A run on a branch that is not yours.*|Drive whichever run `no-mistakes axi status` reports.|' \
    "$brief" > "$control"
  ! brief_refuses_a_foreign_branch_run "$control" \
    || fail "negative control did not go red: the check passes a brief that joins a foreign run"

  pass "a concurrent run on another branch is refused rather than joined"
}

# The certification for this transition is that it is one call inside an
# existing definition of done, not a private runner. A brief that grew a retry
# timer, a poll, or its own watcher would satisfy every check above and still
# be the thing this increment forbids.
test_no_private_loop_runner_is_introduced() {
  local brief starts
  brief=$(scaffold_no_mistakes_brief no-runner)

  starts=$(grep -cF 'no-mistakes axi run --intent' "$brief")
  [ "$starts" = 1 ] \
    || fail "definition of done names $starts run-start calls; the transition is exactly one blocking call"

  local banned
  for banned in 'sleep ' 'watcher' 'cron' 'poll every' 're-run it every'; do
    assert_no_grep "$banned" "$brief" \
      "definition of done introduced a private loop runner ('$banned')"
  done

  pass "the validate transition stays one blocking call, with no poller, timer, or watcher"
}

test_worker_starts_the_run_without_a_firstmate_turn
test_shared_daemon_rule_is_preserved
test_a_foreign_branch_run_is_refused_not_joined
test_no_private_loop_runner_is_introduced
