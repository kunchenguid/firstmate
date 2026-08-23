#!/usr/bin/env bash
# tests/fm-promotion-gate.test.sh - the landing gate for an unanswered routing
# promotion (bin/fm-promotion-gate-lib.sh), driven through BOTH landing paths:
# bin/fm-pr-merge.sh and bin/fm-merge-local.sh.
#
# Why the gate exists: a crewmate that re-resolves its own tier upward mid-task
# opens a durable keyed record, and firstmate owes it a re-staff. Landing is the
# last moment stale rigor can still be corrected, so neither path may land while
# that record is open. These tests drive the REAL scripts over crafted state and
# assert observable outcomes - exit status, refusal text, whether the forge was
# called at all, and whether the project branch actually moved - never the
# libraries' own source text.
#
# Matrix:
#   (a) an open promotion refuses the PR path before any recording or forge call
#   (b) a keyed resolution reopens the PR path
#   (c) an unrelated open decision never trips the gate (it is promotion-specific)
#   (d) the override lands, demands a reason, and records it beside the task
#   (e) an open promotion refuses the local path before the project is touched
#   (f) the override lands the local path and records its reason
#   (g) a ledger that exists but cannot be trusted fails CLOSED; a truly absent one does not
#   (h) an override reason that says nothing is refused in every syntax form
#   (i) the promotion verb is fixed, so a rename cannot disarm the gate
#   (j) the local path refuses an unsafe task id and a diverted override destination
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

PR_MERGE="$ROOT/bin/fm-pr-merge.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-promotion-gate-tests)

PR_URL=https://github.com/example/repo/pull/7

# --- PR-path sandbox --------------------------------------------------------

# A state dir with a ship task's meta and a gh-axi mock that logs every call, so
# "the forge was never reached" is directly observable rather than inferred.
make_pr_case() {  # <name> -> case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/wt" "$fakebin"
  fm_write_meta "$case_dir/state/task-p1.meta" \
    "window=fm-task-p1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_AXI_LOG"
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  : > "$case_dir/gh-axi.log"
  printf '%s\n' "$case_dir"
}

run_pr_merge() {  # <case-dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_TEST_GH_AXI_LOG="$case_dir/gh-axi.log" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_MERGE" "$@"
}

# --- local-path sandbox -----------------------------------------------------

# A real project on its default branch plus an fm/<id> branch one commit ahead,
# which is exactly the shape fm-merge-local.sh fast-forwards.
make_local_case() {  # <name> -> case dir
  local name=$1 case_dir proj default
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  mkdir -p "$case_dir/state"
  fm_git_init_commit "$proj"
  default=$(git -C "$proj" symbolic-ref --short HEAD)
  git -C "$proj" checkout -q -b fm/task-l1
  printf 'landed\n' > "$proj/feature.txt"
  git -C "$proj" add feature.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'feature work'
  git -C "$proj" checkout -q "$default"
  fm_write_meta "$case_dir/state/task-l1.meta" \
    "window=fm-task-l1" \
    "worktree=$proj" \
    "project=$proj" \
    "kind=ship" \
    "mode=local-only"
  printf '%s\n' "$case_dir"
}

local_default_head() {  # <case-dir> -> sha of the project's default branch
  local proj="$1/project"
  git -C "$proj" rev-parse HEAD
}

run_merge_local() {  # <case-dir> <args...>
  local case_dir=$1; shift
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_HOME="$case_dir" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    "$MERGE_LOCAL" "$@"
}

# --- (a) ---------------------------------------------------------------------

test_pr_path_refuses_an_unanswered_promotion() {
  local case_dir rc
  case_dir=$(make_pr_case pr-refuses)
  printf 'working: implementing the bounded change\n' > "$case_dir/state/task-p1.status"
  printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n' \
    >> "$case_dir/state/task-p1.status"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-refuses: an open promotion must refuse the merge"
  assert_grep 'REFUSED' "$case_dir/err" "pr-refuses: the refusal was not reported"
  assert_grep 'tier' "$case_dir/err" "pr-refuses: the refusal did not name the open key"
  assert_grep 'auth policy path' "$case_dir/err" \
    "pr-refuses: the refusal did not carry the promotion's own reason"
  assert_grep 'resolve-key' "$case_dir/err" \
    "pr-refuses: the refusal did not name the route that closes the record"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "pr-refuses: the forge was reached despite the refusal"
  assert_no_grep '^pr=' "$case_dir/state/task-p1.meta" \
    "pr-refuses: a refused merge must not record the PR"
  assert_absent "$case_dir/state/task-p1.promotion-override" \
    "pr-refuses: a refusal must not leave an override record"
  pass "an unanswered promotion refuses the PR path before recording or the forge"
}

# --- (b) ---------------------------------------------------------------------

test_pr_path_reopens_once_the_promotion_is_answered() {
  local case_dir rc
  case_dir=$(make_pr_case pr-answered)
  {
    printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n'
    printf 'resolved [key=tier]: re-staffed onto a stronger runtime, delivery unchanged\n'
  } > "$case_dir/state/task-p1.status"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-answered: an answered promotion must not block the merge"
  grep -q 'pr merge 7 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "pr-answered: the merge did not reach the forge"
  pass "a keyed resolution reopens the PR path"
}

# --- (c) ---------------------------------------------------------------------

# The gate must key on the promotion verb alone. An ordinary open decision or
# blocker has its own handling and must never be silently converted into a
# merge refusal by this gate.
test_other_open_decisions_never_trip_the_gate() {
  local case_dir rc
  case_dir=$(make_pr_case pr-other-decision)
  {
    printf 'needs-decision [key=schema]: column nullable or defaulted?\n'
    printf 'blocked [key=infra]: waiting on staging credentials\n'
  } > "$case_dir/state/task-p1.status"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-other-decision: only a promotion may trip the landing gate"
  grep -q 'pr merge 7 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "pr-other-decision: the merge did not reach the forge"
  pass "an unrelated open decision never trips the promotion gate"
}

test_promotion_survives_a_later_blocker_with_its_key() {
  local case_dir rc
  case_dir=$(make_pr_case pr-promotion-blocked)
  {
    printf 'promoted [key=tier]: tier-2 blast-radius - diff reaches the auth policy path\n'
    printf 'blocked [key=tier]: waiting on a staging credential\n'
  } > "$case_dir/state/task-p1.status"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-promotion-blocked: a later blocker must not replace an open promotion"
  assert_grep 'auth policy path' "$case_dir/err" \
    "pr-promotion-blocked: the gate did not retain the promotion's record"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "pr-promotion-blocked: the forge was reached despite the open promotion"
  pass "a later blocker cannot replace an open promotion"
}

test_ordinary_openers_still_replace_their_shared_key() {
  local case_dir rc open expected
  case_dir=$(make_pr_case pr-ordinary-replace)
  {
    printf 'needs-decision [key=shared]: choose the data shape\n'
    printf 'blocked [key=shared]: waiting on staging credentials\n'
  } > "$case_dir/state/task-p1.status"

  open=$(status_open_decisions "$case_dir/state/task-p1.status")
  expected=$(printf 'shared\tblocked\twaiting on staging credentials')
  [ "$open" = "$expected" ] \
    || fail "pr-ordinary-replace: ordinary opener replacement changed: got '$open' want '$expected'"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-ordinary-replace: an ordinary keyed blocker must not trip the promotion gate"
  grep -q 'pr merge 7 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "pr-ordinary-replace: the merge did not reach the forge"
  pass "ordinary openers still replace their shared key"
}

# --- (d) ---------------------------------------------------------------------

test_override_demands_a_reason_and_records_it() {
  local case_dir rc
  case_dir=$(make_pr_case pr-override)
  printf 'promoted [key=tier]: tier-2 consequence - migration touches real user rows\n' \
    > "$case_dir/state/task-p1.status"

  # The flag without a value is refused outright: an unexplained override is
  # exactly what this gate exists to prevent.
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" --promotion-override \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 2 "$rc" "pr-override: a bare --promotion-override must be refused"
  [ ! -s "$case_dir/gh-axi.log" ] \
    || fail "pr-override: the forge was reached despite a refused override"
  assert_absent "$case_dir/state/task-p1.promotion-override" \
    "pr-override: a refused override must not leave a record"

  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" \
    --promotion-override 'worker gone; re-staffed by hand and re-reviewed at the higher tier' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-override: a reasoned override must land"
  grep -q 'pr merge 7 --repo example/repo' "$case_dir/gh-axi.log" \
    || fail "pr-override: the merge did not reach the forge"
  assert_grep 're-staffed by hand and re-reviewed at the higher tier' \
    "$case_dir/state/task-p1.promotion-override" \
    "pr-override: the stated reason was not recorded beside the task"
  assert_grep 'reason recorded' "$case_dir/err" \
    "pr-override: an override must announce itself rather than landing quietly"
  pass "the override demands a reason and records it beside the task"
}

# --- (e) ---------------------------------------------------------------------

test_local_path_refuses_an_unanswered_promotion() {
  local case_dir rc before after
  case_dir=$(make_local_case local-refuses)
  printf 'promoted [key=tier]: tier-3 consequence - touches the billing path\n' \
    > "$case_dir/state/task-l1.status"
  before=$(local_default_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-l1 > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 1 "$rc" "local-refuses: an open promotion must refuse the local merge"
  assert_grep 'REFUSED' "$case_dir/err" "local-refuses: the refusal was not reported"
  assert_grep 'billing path' "$case_dir/err" \
    "local-refuses: the refusal did not carry the promotion's own reason"
  after=$(local_default_head "$case_dir")
  [ "$before" = "$after" ] \
    || fail "local-refuses: the project's default branch moved despite the refusal"
  pass "an unanswered promotion refuses the local path before the project is touched"
}

# --- (f) ---------------------------------------------------------------------

test_local_path_override_lands_and_records() {
  local case_dir rc before after
  case_dir=$(make_local_case local-override)
  printf 'promoted [key=tier]: tier-3 consequence - touches the billing path\n' \
    > "$case_dir/state/task-l1.status"
  before=$(local_default_head "$case_dir")

  set +e
  run_merge_local "$case_dir" task-l1 \
    --promotion-override 'worker gone and the hold path is unavailable in this home' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-override: a reasoned override must land the local merge"
  after=$(local_default_head "$case_dir")
  [ "$before" != "$after" ] \
    || fail "local-override: the fast-forward did not happen"
  assert_grep 'hold path is unavailable' "$case_dir/state/task-l1.promotion-override" \
    "local-override: the stated reason was not recorded beside the task"
  pass "the override lands the local path and records its reason"
}

# --- (g) ---------------------------------------------------------------------

# The shared fold answers "no open decisions" for a file it cannot read. At a
# landing gate that answer is not the same as "no promotion": an unreadable or
# swapped ledger could be hiding one. Absence is evidence; unreadable presence is
# not, so the two must not behave alike.
test_untrustworthy_ledger_fails_closed_but_absence_does_not() {
  local case_dir rc
  case_dir=$(make_pr_case pr-ledger)

  # Absent ledger: the worker has simply reported nothing yet, which must land.
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 0 "$rc" "pr-ledger: an absent status ledger must not block landing"

  # Unreadable ledger holding a real promotion. Root ignores the mode bits, so the
  # file would stay readable and this case would fail for the wrong reason; the
  # symlink half below covers the same contract for that environment.
  printf 'promoted [key=tier]: tier-2 blast-radius - auth policy path\n' > "$case_dir/state/task-p1.status"
  chmod 000 "$case_dir/state/task-p1.status"
  if [ "$(id -u)" = 0 ]; then
    printf 'skip: unreadable-ledger case needs a non-root user\n'
    chmod 644 "$case_dir/state/task-p1.status"
  else
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  chmod 644 "$case_dir/state/task-p1.status"
  expect_code 1 "$rc" "pr-ledger: an unreadable status ledger must refuse rather than assume no promotion"
  assert_grep 'cannot be read safely' "$case_dir/err" \
    "pr-ledger: the refusal did not explain that the ledger could not be trusted"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "pr-ledger: the forge was reached over an unreadable ledger"
  fi

  # A symlinked ledger is equally untrustworthy even when its target reads fine.
  printf 'working: nothing to see here\n' > "$case_dir/decoy.status"
  rm -f "$case_dir/state/task-p1.status"
  ln -s "$case_dir/decoy.status" "$case_dir/state/task-p1.status"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-ledger: a symlinked status ledger must refuse"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "pr-ledger: the forge was reached over a symlinked ledger"
  pass "an untrustworthy status ledger fails closed while a genuinely absent one lands"
}

# --- (h) ---------------------------------------------------------------------

# The override is allowed to exist only because it records WHY. A reason that
# records nothing is the failure it was meant to prevent, so every shape of
# "no real reason" must be refused - including the separator itself, which a
# naive parser happily swallows as the reason.
test_override_refuses_a_reason_that_says_nothing() {
  local case_dir rc shape
  case_dir=$(make_pr_case pr-empty-reason)
  printf 'promoted [key=tier]: tier-2 consequence - migration touches real user rows\n' \
    > "$case_dir/state/task-p1.status"

  # A carriage return alone records a visually blank line, and a tab-only or
  # mixed-blank reason is no more of a reason than an empty one.
  for shape in '--' '   ' '' '--promotion-override=' '--promotion-override=   ' \
    "$(printf '\r')" "$(printf '\t')" "$(printf ' \r \t ')"; do
    : > "$case_dir/gh-axi.log"
    set +e
    case "$shape" in
      --promotion-override=*)
        run_pr_merge "$case_dir" task-p1 "$PR_URL" "$shape" > "$case_dir/out" 2> "$case_dir/err"
        ;;
      *)
        run_pr_merge "$case_dir" task-p1 "$PR_URL" --promotion-override "$shape" \
          > "$case_dir/out" 2> "$case_dir/err"
        ;;
    esac
    rc=$?
    set -e
    [ "$rc" -ne 0 ] \
      || fail "pr-empty-reason: an override reason of '$shape' must not land the merge"
    [ ! -s "$case_dir/gh-axi.log" ] \
      || fail "pr-empty-reason: the forge was reached with an override reason of '$shape'"
    assert_absent "$case_dir/state/task-p1.promotion-override" \
      "pr-empty-reason: a refused override reason of '$shape' still left a record"
  done
  pass "an override reason that records nothing is refused in every syntax form"
}

# --- (i) ---------------------------------------------------------------------

# The promotion verb is fixed on purpose. An environment that tries to rename it
# must change nothing: if a rename took effect, every record already written with
# the old spelling would stop matching and the gate would proceed silently, which
# is the exact bypass this whole mechanism exists to prevent.
test_the_promotion_verb_cannot_be_renamed_out_from_under_the_gate() {
  local case_dir rc
  case_dir=$(make_pr_case pr-verb)
  printf 'promoted [key=tier]: tier-2 blast-radius - auth policy path\n' \
    > "$case_dir/state/task-p1.status"

  export FM_CLASSIFY_PROMOTION_VERB=escalated
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "pr-verb: an attempted rename must not stop the gate seeing a real promotion"
  [ ! -s "$case_dir/gh-axi.log" ] || fail "pr-verb: an attempted rename let the merge reach the forge"

  # And the renamed spelling is not quietly adopted either: it is simply not the verb.
  printf 'escalated [key=tier]: tier-2 blast-radius - auth policy path\n' \
    > "$case_dir/state/task-p1.status"
  : > "$case_dir/gh-axi.log"
  set +e
  run_pr_merge "$case_dir" task-p1 "$PR_URL" > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  unset FM_CLASSIFY_PROMOTION_VERB
  expect_code 0 "$rc" "pr-verb: a verb that is not the promotion verb must not trip the gate"
  pass "the promotion verb cannot be renamed out from under the landing gate"
}

# --- (j) ---------------------------------------------------------------------

# The local path takes a bare task id and builds paths from it. An id it never
# validates becomes a path traversal, and a plain redirect follows a symlink, so
# the override record could be written anywhere.
test_local_path_refuses_unsafe_ids_and_diverted_records() {
  local case_dir rc outside before after
  case_dir=$(make_local_case local-unsafe)
  printf 'promoted [key=tier]: tier-3 consequence - touches the billing path\n' \
    > "$case_dir/state/task-l1.status"

  set +e
  run_merge_local "$case_dir" ../escape > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  # Assert the DECIDING refusal, not merely a nonzero status: the pre-existing
  # missing-metadata check would satisfy a bare status assertion on its own, which
  # would let the id guard be deleted with this test still green.
  expect_code 2 "$rc" "local-unsafe: a traversing task id must be refused as an id"
  assert_grep 'not a usable task id' "$case_dir/err" \
    "local-unsafe: the refusal came from some other check, so the id guard is untested"

  outside="$case_dir/outside.txt"
  ln -s "$outside" "$case_dir/state/task-l1.promotion-override"
  set +e
  run_merge_local "$case_dir" task-l1 \
    --promotion-override 'worker gone and the hold path is unavailable' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "local-unsafe: a symlinked override destination must be refused"
  assert_absent "$outside" "local-unsafe: the override write escaped through the symlink"

  rm "$case_dir/state/task-l1.promotion-override"
  mkdir "$case_dir/state/task-l1.promotion-override"
  before=$(local_default_head "$case_dir")
  set +e
  run_merge_local "$case_dir" task-l1 \
    --promotion-override 'worker gone and the hold path is unavailable' \
    > "$case_dir/out" 2> "$case_dir/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "local-unsafe: a directory override destination must be refused"
  assert_grep 'is a directory' "$case_dir/err" \
    "local-unsafe: the directory refusal came from another check"
  after=$(local_default_head "$case_dir")
  [ "$before" = "$after" ] \
    || fail "local-unsafe: a directory override destination moved the default branch"
  [ -z "$(find "$case_dir/state/task-l1.promotion-override" -mindepth 1 -maxdepth 1 -print -quit)" ] \
    || fail "local-unsafe: a directory override destination received a hidden record"
  pass "the local path refuses unsafe ids and diverted override records"
}

test_pr_path_refuses_an_unanswered_promotion
test_pr_path_reopens_once_the_promotion_is_answered
test_other_open_decisions_never_trip_the_gate
test_promotion_survives_a_later_blocker_with_its_key
test_ordinary_openers_still_replace_their_shared_key
test_override_demands_a_reason_and_records_it
test_local_path_refuses_an_unanswered_promotion
test_local_path_override_lands_and_records
test_untrustworthy_ledger_fails_closed_but_absence_does_not
test_override_refuses_a_reason_that_says_nothing
test_the_promotion_verb_cannot_be_renamed_out_from_under_the_gate
test_local_path_refuses_unsafe_ids_and_diverted_records
