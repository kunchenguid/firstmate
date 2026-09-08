#!/usr/bin/env bash
# tests/fm-classify-landing.test.sh - a `done:` status line is not by itself
# proof that a ship landed.
#
# The generated no-mistakes contract (bin/fm-dod-lib.sh) asks a worker to append
# `done: <summary>` on its implementation commit and stop, BEFORE the pipeline
# has produced anything, so that line reads exactly like a completion while the
# PR it claims does not exist. Six workers stopped there on 2026-09-07 and two
# more on 2026-09-08 - `done: ... commit b291c234...` and a bare endpoint summary,
# neither carrying a PR URL - and each was read as landed until a supervisor
# steered it back by hand.
#
# The guard is keyed on the task's RECORDED delivery mode, never on an assumption
# that every task ends in a PR, so half of these cases defend the modes that
# legitimately finish without one: turning a correct scout or local-only
# completion into a false alarm would be worse than the bug being fixed.
#
# There is exactly one acceptance path, the URL on the done line itself, so the
# two wider paths that were removed get a refusal case each: a PR mentioned on an
# earlier status line, and a `pr=` record a relaunch carried over from a previous
# incarnation. Both were accepted before, and each is the original defect reached
# through a back door.
#
# Coverage is split by interface: the rule through the library's own sourced
# entry points, and the supervisor-facing rendering through the REAL
# bin/fm-wake-drain.sh, so the reclassification is proven where a supervisor
# actually reads the line rather than only in a predicate.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-classify-landing)

# One task fixture: <case> <meta-kv...> written to state/, with the status log
# supplied on stdin. Echoes the state dir.
make_task() {  # <case-name> <status-lines> <meta-kv>...
  local name=$1 lines=$2 state
  shift 2
  state="$TMP_ROOT/$name/state"
  mkdir -p "$state"
  printf '%s' "$lines" > "$state/task.status"
  [ "$#" -eq 0 ] || fm_write_meta "$state/task.meta" "$@"
  printf '%s\n' "$state"
}

# --- the rule -----------------------------------------------------------------

# The exact 2026-09-07 and 2026-09-08 shape: a completion claimed on an
# implementation commit, on a ship whose recorded mode ends in a PR.
test_commit_done_on_no_mistakes_is_not_a_landing() {
  local state line out
  line='done: aprovacoes endpoint implemented, commit b291c234'
  state=$(make_task nm-commit "working: setup done
$line
" kind=ship mode=no-mistakes)
  status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a commit-only done on a no-mistakes ship must not read as a landing"
  out=$(status_present_line "$line" "$state/task.status")
  assert_contains "$out" "not-landed" "the rendered line must say it is not a landing"
  assert_contains "$out" "no-mistakes" "the rendered line must name the recorded mode"
  assert_contains "$out" "commit b291c234" "the worker's own note must survive rendering"
  case "$out" in
    done:*) fail "the rendered line still opens as a completion: $out" ;;
  esac
  pass "a commit-only done on a no-mistakes ship is rendered as not landed"
}

# The second 2026-09-08 line: a prose summary with no commit and no PR.
test_prose_done_on_no_mistakes_is_not_a_landing() {
  local state line
  line='done: GET /api/aprovacoes/tipos/{id}/documento serve fatias'
  state=$(make_task nm-prose "$line
" kind=ship mode=no-mistakes)
  status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a prose done with no PR must not read as a landing"
  pass "a prose done with no PR on a no-mistakes ship is not a landing"
}

test_commit_done_on_direct_pr_is_not_a_landing() {
  local state line
  line='done: implemented and committed'
  state=$(make_task direct-commit "$line
" kind=ship mode=direct-PR)
  status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "direct-PR also ends in a PR, so this is not a landing either"
  pass "a done with no PR on a direct-PR ship is not a landing"
}

# --- the modes that legitimately end without a PR -----------------------------

test_local_only_completion_is_accepted() {
  local state line out
  line='done: ready in branch fm/task'
  state=$(make_task local-only "$line
" kind=ship mode=local-only)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a local-only ship ends at a clean branch and must stay accepted"
  out=$(status_present_line "$line" "$state/task.status")
  [ "$out" = "$line" ] || fail "a local-only completion was rewritten: $out"
  pass "a local-only completion is accepted unchanged"
}

test_scout_completion_is_accepted() {
  local state line out
  line='done: report written to data/task/report.md'
  state=$(make_task scout "$line
" kind=scout)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a scout records no delivery mode and must stay accepted"
  out=$(status_present_line "$line" "$state/task.status")
  [ "$out" = "$line" ] || fail "a scout completion was rewritten: $out"
  pass "a scout completion is accepted unchanged"
}

test_secondmate_completion_is_accepted() {
  local state line
  line='done: routed work finished'
  state=$(make_task secondmate "$line
" kind=secondmate mode=secondmate)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "mode=secondmate does not end in a PR"
  pass "a secondmate completion is accepted unchanged"
}

test_absent_and_unusable_records_are_accepted() {
  local state line
  line='done: finished'
  state=$(make_task no-meta "$line
")
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a task with no metadata must never be refused"
  state=$(make_task blank-mode "$line
" kind=ship)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a task with no recorded mode must never be refused"
  state=$(make_task odd-mode "$line
" kind=ship mode=some-future-mode)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "an unrecognized mode is not evidence that a PR is owed"
  pass "absent, blank, and unrecognized delivery modes are accepted"
}

test_non_done_verbs_are_untouched() {
  local state line
  state=$(make_task verbs "working: still going
" kind=ship mode=no-mistakes)
  for line in 'working: still going' 'blocked: needs a credential' \
    'needs-decision [key=k]: which shape?' 'failed: could not build' \
    'paused: waiting on an upstream release'; do
    ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
      || fail "only a done line may be reclassified, not: $line"
  done
  pass "no verb other than done is reclassified"
}

# --- the evidence that a PR does exist ----------------------------------------

test_pr_url_on_the_line_is_a_landing() {
  local state line out
  line='done: PR https://github.com/kunchenguid/firstmate/pull/3951 checks green'
  state=$(make_task pr-on-line "$line
" kind=ship mode=no-mistakes)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a done carrying its PR URL is a landing"
  out=$(status_present_line "$line" "$state/task.status")
  [ "$out" = "$line" ] || fail "a real landing was rewritten: $out"
  pass "a done carrying a PR URL is accepted unchanged"
}

test_gitlab_merge_request_counts_as_a_pr() {
  local state line
  line='done: MR https://gitlab.example.com/group/sub/proj/-/merge_requests/7 checks green'
  state=$(make_task pr-gitlab "$line
" kind=ship mode=no-mistakes)
  ! status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a GitLab merge request is a PR for this purpose"
  pass "a GitLab merge request counts as a PR"
}

# The file-taking scraper the fleet snapshot's PR column and the inactive
# reconciler read a whole status log with. It answers exactly what the
# text-taking form answers for the same content, on both forges and in log order.
test_file_scraper_matches_the_text_scraper() {
  local state text file_urls
  text='working: opened https://gitlab.example.com/g/p/-/merge_requests/7
working: superseded by https://github.com/o/r/pull/12
'
  state=$(make_task pr-scrape-file "$text")
  file_urls=$(status_pr_urls_file "$state/task.status")
  [ "$file_urls" = "$(status_pr_urls "$text")" ] \
    || fail "the file scraper disagreed with the text scraper: $file_urls"
  [ "$(status_file_pr_url "$state/task.status")" \
    = 'https://gitlab.example.com/g/p/-/merge_requests/7' ] \
    || fail "the file scraper did not return the first URL"
  : > "$state/task.status"
  [ -z "$(status_file_pr_url "$state/task.status")" ] \
    || fail "an empty log yielded a PR URL"
  pass "the file scraper answers what the text scraper answers"
}

# --- the acceptance paths that were deliberately removed ----------------------
#
# Both of these passed before the guard collapsed to one acceptance path, and
# each is the original defect reachable through a back door, so they are the
# cases that prove the doors are shut.

# An earlier line mentioning a PR must not authorize every later PR-less done.
# A worker reviewing feedback on someone else's PR writes exactly this shape.
test_pr_on_an_earlier_line_is_not_a_landing() {
  local state line
  line='done: endpoint implemented'
  state=$(make_task pr-earlier "working: reviewing feedback on PR https://github.com/kunchenguid/firstmate/pull/4001
$line
" kind=ship mode=no-mistakes)
  status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a PR on an earlier line must not authorize a later PR-less done"
  pass "a PR reported on an earlier status line is not a landing"
}

# A relaunch carries the previous incarnation's pr= into the new metadata, so a
# recorded PR proves nothing about the completion being claimed now.
test_recorded_pr_metadata_is_not_a_landing() {
  local state line
  line='done: endpoint implemented, commit b291c234'
  state=$(make_task pr-in-meta "$line
" kind=ship mode=no-mistakes \
    pr=https://github.com/kunchenguid/firstmate/pull/3951)
  status_done_without_pr "$line" "$state/task.status" >/dev/null \
    || fail "a relaunched task's inherited pr= must not authorize a PR-less done"
  pass "a PR recorded in the task metadata is not a landing"
}

# --- the supervisor-facing surface --------------------------------------------

# The drain annotation is where a supervisor reads the status line itself, so the
# reclassification has to survive the real drain, not only the predicate.
test_drain_annotation_cannot_be_read_as_a_landing() {
  local dir state out
  dir=$(make_case drain-not-landed)
  state="$dir/state"
  fm_write_meta "$state/ship.meta" window=fm:fm-ship worktree="$dir" kind=ship mode=no-mistakes
  printf 'done: aprovacoes endpoint implemented, commit b291c234\n' > "$state/ship.status"
  fm_write_meta "$state/rep.meta" window=fm:fm-rep worktree="$dir" kind=scout
  printf 'done: report written to data/rep/report.md\n' > "$state/rep.status"
  out="$dir/drain.out"
  append_wake "$state" signal ship.status "signal: $state/ship.status" \
    || fail "ship wake append failed"
  append_wake "$state" signal rep.status "signal: $state/rep.status" \
    || fail "scout wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "drain failed"

  grep -F 'ship.status: not-landed' "$out" >/dev/null \
    || fail "the drain still presented a PR-less done as a plain completion"$'\n'"$(cat "$out")"
  grep -E '^wake annotation:.*ship\.status: done:' "$out" >/dev/null \
    && fail "the drain presented the ship line so it opens as a completion"$'\n'"$(cat "$out")"
  grep -Fx "wake annotation: latest wake-EVENT observed at drain, not current state: rep.status: done: report written to data/rep/report.md" "$out" >/dev/null \
    || fail "the scout completion was altered by the drain"$'\n'"$(cat "$out")"
  pass "the drain renders a PR-less done as not landed and leaves a scout alone"
}

test_commit_done_on_no_mistakes_is_not_a_landing
test_prose_done_on_no_mistakes_is_not_a_landing
test_commit_done_on_direct_pr_is_not_a_landing
test_local_only_completion_is_accepted
test_scout_completion_is_accepted
test_secondmate_completion_is_accepted
test_absent_and_unusable_records_are_accepted
test_non_done_verbs_are_untouched
test_pr_url_on_the_line_is_a_landing
test_gitlab_merge_request_counts_as_a_pr
test_file_scraper_matches_the_text_scraper
test_pr_on_an_earlier_line_is_not_a_landing
test_recorded_pr_metadata_is_not_a_landing
test_drain_annotation_cannot_be_read_as_a_landing

echo "all fm-classify-landing tests passed"
