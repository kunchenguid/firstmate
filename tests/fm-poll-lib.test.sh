#!/usr/bin/env bash
# Tests for bin/fm-poll-lib.sh, the decision logic behind a task's armed PR/MR
# poll, and for the upgrade path that carries it into polls generated before the
# library existed.
#
# The bug these exist for: bin/fm-pr-check.sh used to inline the poll's whole
# judgement into the state/<id>.check.sh it wrote, and that file is never
# rewritten. A poll armed on 2026-07-17 was therefore still asking only
# "merged?" weeks later - blind to every signal added since - while a poll armed
# after the change saw them. Case (j) is the regression test for that: it drives
# a byte-exact copy of the real frozen pre-library file and requires it to
# produce today's signals with its own contents untouched.
#
# Matrix:
#   (a) an open PR with no watch run stays silent
#   (b) a merged PR wakes with "merged" and clears the poll's own state
#   (b1) a merged PR also ENDS this task's watch run, which nothing else does
#   (b2) it ends only the run recorded as this task's, never another's
#   (b3) a task with no recorded run ends nothing at all
#   (b4) an ending that fails stays silent and leaves the merge answer alone
#   (b5) ending an already-ended run is a harmless no-op on every later poll
#   (b6) a pre-library poll ends its watch run too, its own file untouched
#   (c) this task's parked watch run wakes once, then stays quiet while parked
#   (d) a park that clears re-arms the one-shot, so a later park wakes again
#   (e) ANOTHER run's park is never reported - the captain's own no-mistakes
#       work is not firstmate's to read, report, or answer
#   (f) a watch run that is gone wakes once, with the re-arm instruction
#   (g) a run status the vocabulary does not know is not reported as gone
#   (h) a watch lookup that cannot answer fails closed with the broken
#       diagnostic, never as a signal
#   (i) a task with no recorded run id asks no watch question at all
#   (j) a poll generated before bin/fm-poll-lib.sh existed picks up today's
#       signals without its file being touched
#   (k) a re-armed watch (a new run id) can report a park again
#
# Cases (a) to (i) and (k) drive the poll the way bin/fm-watch.sh does, through
# bin/fm-pr-poll.sh with the published poll path, because that path is what
# carries the task identity the watch questions need; bin/fm-poll-extra.sh is
# what answers them. Case (j) drives its own frozen file instead, which is the
# whole point of that case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-poll-lib-tests)
PR_URL=https://github.com/example/repo/pull/7
MY_RUN=01KRUNMINE0000000000000001
THEIR_RUN=01KRUNTHEIRS000000000000009

# A sandbox with a state dir, a task meta, a git checkout for the run lookup to
# run in, and mocks for gh, no-mistakes, and the two files that drive them:
#   <case>/pr-state          what `gh pr view` reports (default OPEN)
#   <case>/parked.json       what `no-mistakes parked --json` returns
#   <case>/run-<id>.toon     the `axi status --run <id>` record; absent = not found
make_case() {  # <name> -> case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$fakebin"
  fm_git_init_commit "$case_dir/wt"
  fm_write_meta "$case_dir/state/task-p1.meta" \
    "window=fm-task-p1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/wt" \
    "kind=ship" \
    "mode=direct-PR" \
    "pr=$PR_URL"
  printf 'OPEN\n' > "$case_dir/pr-state"
  printf '[]\n' > "$case_dir/parked.json"

  cat > "$fakebin/gh" <<SH
#!/usr/bin/env bash
case " \$* " in
  *"state,headRefOid"*)
    if [ -e '$case_dir/gh-broken' ]; then
      echo "gh: authentication failed" >&2
      exit 1
    fi
    printf '%s\t%s\n' "\$(cat '$case_dir/pr-state')" '9999999999999999999999999999999999999999'
    exit 0
    ;;
  *"--json state -q"*)
    # bin/fm-pr-poll.sh asks for the state alone. Answering only the older
    # two-field query made this mock return nothing here, so a merged PR read as
    # silence and the poll looked broken when it was the mock that was.
    if [ -e '$case_dir/gh-broken' ]; then
      echo "gh: authentication failed" >&2
      exit 1
    fi
    cat '$case_dir/pr-state'
    exit 0
    ;;
esac
exit 0
SH

  # Mirrors the real CLI: \`parked --json\` prints the machine-wide record and
  # exits 1 when nothing is parked; \`axi status --run\` resolves a run by id
  # alone and exits 1 with a "not found" error when there is no such run; and
  # \`axi abort --run\` ends a live run, but on a run that already ended it is an
  # explicit no-op that still exits 0 - verified 2026-07-25 against the real
  # no-mistakes 60d5741, which is where the ending's idempotency comes from.
  # Every abort is logged before anything else, so a case can prove which runs
  # were touched and which were not even reached.
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = "axi abort" ]; then
  run=\$4
  printf '%s\n' "\$run" >> '$case_dir/abort.log'
  if [ -e '$case_dir/abort-broken' ]; then
    echo "no-mistakes: cannot reach the daemon" >&2
    exit 7
  fi
  toon="$case_dir/run-\$run.toon"
  if [ -f "\$toon" ] && ! grep -qE '  status: (cancelled|completed|failed|interrupted)' "\$toon"; then
    sed -i.bak 's/^  status: .*/  status: cancelled/' "\$toon"
    rm -f "\$toon.bak"
    printf 'aborted: true\nrun: "%s"\n' "\$run"
    exit 0
  fi
  printf 'aborted: false\nrun: "%s"\ndetail: no active run with that id (no-op)\n' "\$run"
  exit 0
fi
if [ -e '$case_dir/nm-broken' ]; then
  echo "no-mistakes: cannot reach state" >&2
  exit 3
fi
case "\$1 \$2" in
  "parked --json")
    cat '$case_dir/parked.json'
    grep -q '"run"' '$case_dir/parked.json' && exit 0
    exit 1
    ;;
  "axi status")
    run=\$4
    if [ -f "$case_dir/run-\$run.toon" ]; then
      cat "$case_dir/run-\$run.toon"
      exit 0
    fi
    printf 'error: "run \\\\"%s\\\\" not found"\n' "\$run"
    exit 1
    ;;
esac
exit 2
SH
  chmod +x "$fakebin/gh" "$fakebin/no-mistakes"
  printf '%s\n' "$case_dir"
}

arm_poll() {  # <case-dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_GUARD_GRACE=999999 \
  PATH="$case_dir/fakebin:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-p1 "$PR_URL" --no-watch >/dev/null 2>&1 \
    || fail "fm-pr-check.sh failed to arm the poll"
}

# One poll cycle exactly as bin/fm-watch.sh runs it: the tracked program under
# bin/, the validated PR data, and the poll's published path so the task behind
# it can be named. The copy under state/ is the watcher's byte-identity record,
# not what it executes; tests/fm-pr-merge.test.sh covers running that copy alone.
run_poll() {  # <case-dir>
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" "$ROOT/bin/fm-pr-poll.sh" --validated \
    github "$PR_URL" github.com example/repo 7 \
    "$case_dir/state/task-p1.check.sh" 2>/dev/null
}

# The pre-library poll runs itself: its whole judgement is its own file.
run_legacy_poll() {  # <case-dir>
  local case_dir=$1
  PATH="$case_dir/fakebin:$PATH" bash "$case_dir/state/task-p1.check.sh" 2>/dev/null
}

watch_run() {  # <case-dir> <run-id>
  printf 'nm_watch_run=%s\n' "$2" >> "$1/state/task-p1.meta"
}

run_record() {  # <case-dir> <run-id> <status>
  printf 'run:\n  id: "%s"\n  branch: fm/task-p1\n  status: %s\n  head: abc1234\n' \
    "$2" "$3" > "$1/run-$2.toon"
}

run_status() {  # <case-dir> <run-id>
  sed -n 's/^  status: //p' "$1/run-$2.toon" 2>/dev/null | head -1
}

# Every run id `axi abort --run` was called with, one per line.
abort_log() {  # <case-dir>
  cat "$1/abort.log" 2>/dev/null || true
}

# A parked.json entry for <run-id>. The captain's own run is always in the
# record too, so every read has something to wrongly report if the filter leaks.
parked_record() {  # <case-dir> [run-id ...]
  local case_dir=$1 run entries=
  shift
  entries='{"run":"'$THEIR_RUN'","repo":"/captain/own/repo","branch":"wip","step":"review","gate":"fix_review","parked_for":"2h","findings":[{"id":"captain-private","description":"a finding in the captain'"'"'s own repo"}]}'
  for run in "$@"; do
    entries="$entries,"'{"run":"'$run'","repo":"/p","branch":"fm/task-p1","step":"watch","gate":"review_threads","parked_for":"20m","findings":[{"id":"unresolved-thread","description":"2 unresolved review threads on the PR"}]}'
  done
  printf '[%s]\n' "$entries" > "$case_dir/parked.json"
}

test_open_pr_is_silent() {
  local case_dir out
  case_dir=$(make_case open-silent)
  arm_poll "$case_dir"
  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "open-silent: an open PR with no watch must not wake firstmate (got '$out')"
  pass "an open PR with no watch run keeps the poll silent"
}

test_merged_wakes_and_clears_state() {
  local case_dir out
  case_dir=$(make_case merged)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"
  run_poll "$case_dir" >/dev/null

  printf 'MERGED\n' > "$case_dir/pr-state"
  out=$(run_poll "$case_dir")
  [ "$out" = merged ] || fail "merged: a merged PR must wake with exactly 'merged' (got '$out')"
  assert_absent "$case_dir/state/task-p1.check.nm" \
    "merged: landing must clear the watch one-shot state"
  assert_absent "$case_dir/state/task-p1.check.fails" \
    "merged: landing must clear the consecutive-failure count"
  pass "a merged PR wakes firstmate with 'merged' and clears the poll's own state"
}

# --- the watch run a landing retires ----------------------------------------
# The bug these cover: the merged branch cleared the poll's own bookkeeping and
# left the no-mistakes watch run it had been reporting on alive. Nothing else
# ever ends such a run - the daemon parks an external watch on the first thing
# needing a person and a parked run stops polling, so the merge never reaches it
# - so it stayed on the books until a person aborted it by hand, and the task's
# cleanup was held up for as long as it did. Three direct-PR tasks landed that
# way on 2026-07-24 and 2026-07-25 here; bin/fm-poll-lib.sh's
# fm_poll_end_watch_run header records their ids and the evidence.

test_merged_ends_this_tasks_watch_run() {
  local case_dir out
  case_dir=$(make_case merged-ends-watch)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"
  run_poll "$case_dir" >/dev/null

  printf 'MERGED\n' > "$case_dir/pr-state"
  out=$(run_poll "$case_dir")

  [ "$out" = merged ] \
    || fail "merged-ends-watch: the merge answer must still be exactly 'merged' (got '$out')"
  assert_contains "$(abort_log "$case_dir")" "$MY_RUN" \
    "merged-ends-watch: landing left this task's watch run on the books, which is the run teardown then refuses over"
  [ "$(run_status "$case_dir" "$MY_RUN")" = cancelled ] \
    || fail "merged-ends-watch: the watch run is still $(run_status "$case_dir" "$MY_RUN") after its PR merged"
  pass "a merged PR ends the watch run it retires instead of leaving it on the books"
}

test_merged_never_ends_another_runs_work() {
  local case_dir out
  case_dir=$(make_case merged-end-not-mine)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  # The captain's own run is live in the same machine-wide record this poll
  # reads, and it belongs to no task. Landing this task's PR says nothing at all
  # about it.
  run_record "$case_dir" "$THEIR_RUN" running
  parked_record "$case_dir" "$MY_RUN"

  printf 'MERGED\n' > "$case_dir/pr-state"
  out=$(run_poll "$case_dir")

  [ "$out" = merged ] \
    || fail "merged-end-not-mine: the merge answer must still be exactly 'merged' (got '$out')"
  assert_contains "$(abort_log "$case_dir")" "$MY_RUN" \
    "merged-end-not-mine: this task's own watch run was not ended"
  assert_not_contains "$(abort_log "$case_dir")" "$THEIR_RUN" \
    "merged-end-not-mine: the poll ended a no-mistakes run that was never this task's"
  [ "$(run_status "$case_dir" "$THEIR_RUN")" = running ] \
    || fail "merged-end-not-mine: another run was cancelled by this task's landing"
  pass "landing ends only the run recorded as this task's, never another's"
}

test_merged_with_no_recorded_run_ends_nothing() {
  local case_dir out
  case_dir=$(make_case merged-end-no-run)
  arm_poll "$case_dir"
  # No nm_watch_run in the meta, but the captain's own run IS live and parked.
  run_record "$case_dir" "$THEIR_RUN" running
  parked_record "$case_dir"

  printf 'MERGED\n' > "$case_dir/pr-state"
  out=$(run_poll "$case_dir")

  [ "$out" = merged ] \
    || fail "merged-end-no-run: the merge answer must still be exactly 'merged' (got '$out')"
  [ -z "$(abort_log "$case_dir")" ] \
    || fail "merged-end-no-run: a task with no recorded watch run ended something anyway: $(abort_log "$case_dir")"
  pass "a task with no recorded watch run ends nothing when its PR lands"
}

test_merged_ending_failure_stays_silent() {
  local case_dir first second third fourth
  case_dir=$(make_case merged-end-fails)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  # What a dead daemon or a revoked auth looks like from here: the PR still
  # reads as merged, and only the ending fails.
  : > "$case_dir/abort-broken"
  printf 'MERGED\n' > "$case_dir/pr-state"

  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")
  third=$(run_poll "$case_dir")
  fourth=$(run_poll "$case_dir")

  [ "$first" = merged ] && [ "$second" = merged ] \
    && [ "$third" = merged ] && [ "$fourth" = merged ] \
    || fail "merged-end-fails: a failed ending must not change the merge answer (got '$first' '$second' '$third' '$fourth')"
  assert_not_contains "$first$second$third$fourth" "poll broken" \
    "merged-end-fails: a failed ending must never become the broken-poll diagnostic"
  assert_absent "$case_dir/state/task-p1.check.error" \
    "merged-end-fails: a failed ending left a broken-poll marker behind"
  assert_contains "$(abort_log "$case_dir")" "$MY_RUN" \
    "merged-end-fails: the poll gave up on ending the run instead of retrying next cycle"
  [ "$(run_status "$case_dir" "$MY_RUN")" = running ] \
    || fail "merged-end-fails: the fixture did not actually fail the ending"
  pass "an ending that cannot complete stays silent and leaves the merge answer alone"
}

test_merged_ending_is_idempotent() {
  local case_dir first second
  case_dir=$(make_case merged-end-again)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  printf 'MERGED\n' > "$case_dir/pr-state"

  first=$(run_poll "$case_dir")
  [ "$(run_status "$case_dir" "$MY_RUN")" = cancelled ] \
    || fail "merged-end-again: the first cycle did not end the run"
  # The poll stays armed until teardown, so a merged PR keeps being polled. The
  # real CLI answers a repeat abort with an explicit no-op and exit 0, and the
  # run record is left exactly as the first ending left it.
  second=$(run_poll "$case_dir")

  [ "$first" = merged ] && [ "$second" = merged ] \
    || fail "merged-end-again: every merged cycle must answer 'merged' (got '$first' '$second')"
  [ "$(run_status "$case_dir" "$MY_RUN")" = cancelled ] \
    || fail "merged-end-again: a repeat ending disturbed an already-ended run"
  [ "$(abort_log "$case_dir" | wc -l | tr -d ' ')" = 2 ] \
    || fail "merged-end-again: expected one ending attempt per merged cycle, got: $(abort_log "$case_dir")"
  pass "ending an already-ended watch run is a harmless no-op on every later poll"
}

test_park_wakes_once() {
  local case_dir first second
  case_dir=$(make_case park-once)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"

  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")
  assert_contains "$first" "watch parked" \
    "park-once: this task's parked watch run must wake firstmate"
  assert_contains "$first" "$MY_RUN" "park-once: the wake did not name the run"
  assert_contains "$first" "unresolved-thread" \
    "park-once: the wake carried no finding detail to act on"
  [ -z "$second" ] || fail "park-once: a park already reported must not re-wake every poll (got '$second')"
  pass "this task's parked watch run wakes firstmate once and stays quiet while it stays parked"
}

test_park_clearing_rearms_the_one_shot() {
  local case_dir first cleared again
  case_dir=$(make_case park-rearm)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"

  first=$(run_poll "$case_dir")
  assert_contains "$first" "watch parked" "park-rearm: the first park should wake firstmate"

  parked_record "$case_dir"
  cleared=$(run_poll "$case_dir")
  [ -z "$cleared" ] || fail "park-rearm: an answered park must not wake firstmate (got '$cleared')"

  parked_record "$case_dir" "$MY_RUN"
  again=$(run_poll "$case_dir")
  assert_contains "$again" "watch parked" \
    "park-rearm: a later park after the first cleared must wake firstmate again"
  pass "a park that clears re-arms the one-shot so a later park wakes firstmate again"
}

test_another_runs_park_is_never_reported() {
  local case_dir out
  case_dir=$(make_case park-not-mine)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  # Only the captain's own run is parked. It is in the same machine-wide record
  # this poll reads, and it belongs to no task: firstmate must not see it.
  parked_record "$case_dir"

  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "park-not-mine: another run's park must never wake firstmate (got '$out')"
  assert_no_grep "$THEIR_RUN" "$case_dir/state/task-p1.check.nm" \
    "park-not-mine: another run's id was recorded in this task's poll state"
  pass "a park belonging to another run is never read as this task's"
}

test_gone_watch_wakes_once_with_the_rearm() {
  local case_dir first second
  case_dir=$(make_case watch-gone)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  # No run record: the run id is not on no-mistakes' books at all.
  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")

  assert_contains "$first" "watch gone" \
    "watch-gone: a watch run that no longer exists must wake firstmate"
  assert_contains "$first" "fm-nm-watch.sh" \
    "watch-gone: the wake must say how to restore the watch"
  [ -z "$second" ] || fail "watch-gone: a gone watch must not re-wake every poll (got '$second')"

  # An ended run is the same answer as a missing one.
  run_record "$case_dir" "$MY_RUN" completed
  rm -f "$case_dir/state/task-p1.check.nm"
  first=$(run_poll "$case_dir")
  assert_contains "$first" "watch gone" \
    "watch-gone: a completed watch run must wake firstmate to re-arm"
  pass "a watch run that is gone or ended wakes firstmate once with the re-arm instruction"
}

test_unknown_status_is_not_reported_as_gone() {
  local case_dir out
  case_dir=$(make_case watch-unknown)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" some_future_state

  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "watch-unknown: an unrecognized run status must not be guessed as gone (got '$out')"
  pass "a run status the poll does not recognize is left undecided, not reported as gone"
}

test_watch_lookup_failure_fails_closed() {
  local case_dir first second third fourth
  case_dir=$(make_case watch-unreadable)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  # The PR itself still reads fine; only no-mistakes cannot answer, which is what
  # a dead daemon or a missing binary looks like from here.
  : > "$case_dir/nm-broken"

  first=$(run_poll "$case_dir")
  second=$(run_poll "$case_dir")
  third=$(run_poll "$case_dir")
  fourth=$(run_poll "$case_dir")

  [ -z "$first" ] || fail "watch-unreadable: one transient failure must stay quiet (got '$first')"
  [ -z "$second" ] || fail "watch-unreadable: a second transient failure must stay quiet (got '$second')"
  assert_contains "$third" "poll broken" \
    "watch-unreadable: a persistent watch lookup failure must wake firstmate with the diagnostic"
  [ -z "$fourth" ] || fail "watch-unreadable: the diagnostic must not repeat every poll (got '$fourth')"
  assert_not_contains "$first$second$third" "watch gone" \
    "watch-unreadable: an unreadable lookup must never be reported as a gone watch"
  assert_not_contains "$first$second$third" "watch parked" \
    "watch-unreadable: an unreadable lookup must never be reported as a park"
  assert_present "$case_dir/state/task-p1.check.error" \
    "watch-unreadable: no durable marker was left for the broken poll"
  pass "a watch lookup that cannot answer fails closed instead of inventing a signal"
}

test_no_recorded_run_asks_no_watch_question() {
  local case_dir out
  case_dir=$(make_case no-run-id)
  arm_poll "$case_dir"
  # No nm_watch_run in the meta, but the captain's own run IS parked.
  parked_record "$case_dir"
  : > "$case_dir/nm-broken"

  out=$(run_poll "$case_dir")
  [ -z "$out" ] || fail "no-run-id: a task with no watch run must ask no watch question (got '$out')"
  assert_absent "$case_dir/state/task-p1.check.nm" \
    "no-run-id: a task with no watch run must keep no watch state"
  pass "a task with no recorded watch run asks no watch question at all"
}

test_rearmed_watch_can_park_again() {
  local case_dir first second
  case_dir=$(make_case park-rearmed-run)
  arm_poll "$case_dir"
  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"
  first=$(run_poll "$case_dir")
  assert_contains "$first" "watch parked" "park-rearmed-run: the first park should wake firstmate"

  # Answering the park ends the run; re-arming records a new one, which parks in
  # its turn. The one-shot is keyed to the run, so this is a new signal.
  watch_run "$case_dir" "${MY_RUN}2"
  run_record "$case_dir" "${MY_RUN}2" running
  parked_record "$case_dir" "${MY_RUN}2"
  second=$(run_poll "$case_dir")
  assert_contains "$second" "watch parked" \
    "park-rearmed-run: a park on the re-armed run must wake firstmate again"
  assert_contains "$second" "${MY_RUN}2" "park-rearmed-run: the wake named the wrong run"
  pass "a re-armed watch run reports its own park rather than inheriting the answered one"
}

# The generated poll as bin/fm-pr-check.sh wrote it before bin/fm-poll-lib.sh
# existed: a byte-for-byte copy of state/traex-harness-adopt-k2.check.sh (armed
# 2026-07-17), with only the embedded absolute paths and PR URL substituted.
# Its whole judgement is inlined and knows one signal.
write_legacy_poll() {  # <case-dir>
  local case_dir=$1
  cat > "$case_dir/state/task-p1.check.sh" <<SH
# shellcheck shell=bash
fm_scm_lib='$ROOT/bin/fm-scm-lib.sh'
fm_scm_marker='$case_dir/state/task-p1.check.error'
fm_scm_fails='$case_dir/state/task-p1.check.fails'
fm_scm_wake_after=\${FM_CHECK_FAIL_WAKE_AFTER:-3}
case "\$fm_scm_wake_after" in ''|0|*[!0-9]*) fm_scm_wake_after=3 ;; esac

fm_scm_report_broken() {
  [ -e "\$fm_scm_marker" ] && return 0
  : > "\$fm_scm_marker" 2>/dev/null || true
  echo "poll broken: \$1; merge polling for '$PR_URL' is not running"
}

# shellcheck source=bin/fm-scm-lib.sh
if [ ! -r "\$fm_scm_lib" ] || ! . "\$fm_scm_lib"; then
  fm_scm_report_broken "cannot load \$fm_scm_lib"
  exit 0
fi

fails=\$(cat "\$fm_scm_fails" 2>/dev/null || true)
case "\$fails" in ''|*[!0-9]*) fails=0 ;; esac
fails=\$((fails + 1))
printf '%s\n' "\$fails" > "\$fm_scm_fails" 2>/dev/null || true

if state=\$(fm_scm_pr_state "" '$PR_URL' 2>/dev/null); then
  rm -f "\$fm_scm_fails"
  case "\$state" in
    MERGED|merged) echo "merged" ;;
  esac
  exit 0
fi

if [ "\$fails" -ge "\$fm_scm_wake_after" ]; then
  fm_scm_report_broken "cannot read PR/MR state after \$fails consecutive lookup failures (check gh/bytedcli auth)"
fi
SH
}

test_legacy_poll_gains_todays_signals_untouched() {
  local case_dir before after parked gone merged
  case_dir=$(make_case legacy-upgrade)
  write_legacy_poll "$case_dir"
  before=$(cksum < "$case_dir/state/task-p1.check.sh")
  assert_no_grep 'fm_poll_run' "$case_dir/state/task-p1.check.sh" \
    "legacy-upgrade: the fixture is not a pre-library poll"

  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  parked_record "$case_dir" "$MY_RUN"
  parked=$(run_legacy_poll "$case_dir")
  assert_contains "$parked" "watch parked" \
    "legacy-upgrade: a poll armed before the library must still gain the park signal"

  parked_record "$case_dir"
  rm -f "$case_dir/run-$MY_RUN.toon"
  gone=$(run_legacy_poll "$case_dir")
  assert_contains "$gone" "watch gone" \
    "legacy-upgrade: a poll armed before the library must still gain the gone-watch signal"

  printf 'MERGED\n' > "$case_dir/pr-state"
  merged=$(run_legacy_poll "$case_dir")
  [ "$merged" = merged ] || fail "legacy-upgrade: the signal it already had must keep working (got '$merged')"

  after=$(cksum < "$case_dir/state/task-p1.check.sh")
  [ "$before" = "$after" ] \
    || fail "legacy-upgrade: the frozen poll file was rewritten; the upgrade must need no regeneration"
  pass "a poll generated before the library picks up today's signals with its own file untouched"
}

test_legacy_poll_ends_the_watch_run_on_merge() {
  local case_dir before after merged
  case_dir=$(make_case legacy-ends-watch)
  write_legacy_poll "$case_dir"
  before=$(cksum < "$case_dir/state/task-p1.check.sh")

  watch_run "$case_dir" "$MY_RUN"
  run_record "$case_dir" "$MY_RUN" running
  printf 'MERGED\n' > "$case_dir/pr-state"
  merged=$(run_legacy_poll "$case_dir")

  [ "$merged" = merged ] \
    || fail "legacy-ends-watch: the merge answer must still be exactly 'merged' (got '$merged')"
  assert_contains "$(abort_log "$case_dir")" "$MY_RUN" \
    "legacy-ends-watch: a poll armed before the library still leaves its watch run on the books"
  [ "$(run_status "$case_dir" "$MY_RUN")" = cancelled ] \
    || fail "legacy-ends-watch: the watch run is still $(run_status "$case_dir" "$MY_RUN") after its PR merged"

  after=$(cksum < "$case_dir/state/task-p1.check.sh")
  [ "$before" = "$after" ] \
    || fail "legacy-ends-watch: the frozen poll file was rewritten; the upgrade must need no regeneration"
  pass "a poll armed before the library ends its watch run on merge with its own file untouched"
}

test_open_pr_is_silent
test_merged_wakes_and_clears_state
test_merged_ends_this_tasks_watch_run
test_merged_never_ends_another_runs_work
test_merged_with_no_recorded_run_ends_nothing
test_merged_ending_failure_stays_silent
test_merged_ending_is_idempotent
test_legacy_poll_ends_the_watch_run_on_merge
test_park_wakes_once
test_park_clearing_rearms_the_one_shot
test_another_runs_park_is_never_reported
test_gone_watch_wakes_once_with_the_rearm
test_unknown_status_is_not_reported_as_gone
test_watch_lookup_failure_fails_closed
test_no_recorded_run_asks_no_watch_question
test_rearmed_watch_can_park_again
test_legacy_poll_gains_todays_signals_untouched
