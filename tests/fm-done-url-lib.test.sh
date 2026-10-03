#!/usr/bin/env bash
# Behavior tests for bin/fm-done-url-lib.sh, the single owner of "a recorded
# completion names the registered project's pull request, or declares a
# delivery that publishes none".
#
# WHY THIS EXISTS, WITH THE RECORD BEHIND IT (data/backlog.md and
# data/done-archive.md, counted rather than estimated): of the ship-kind Done
# rows this home recorded for the night of 2026-10-01/02, 26 rows are dated to
# that window and ZERO carry a pull-request URL; across all recorded ship-kind
# Done rows, 41 of 79 carry none. A surviving status record from that window
# shows the shape those rows came from -
# state/orbbot-steer-into-running-turn-a1.status line 3 reads
#   done [at=1790869885]: steer shipped on fm/orbbot-steer-into-running-turn-a1
#   (d269b60, fe8e26c): ...
# a completion naming a branch and two commits and never a pull request, with
# the work living in that task's own copy. Each of those jobs was found by
# reading the forge by hand, because nothing refused the line. Every case below
# is a shape that record shows a real run of.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-done-url-lib.sh
. "$ROOT/bin/fm-done-url-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-done-url)
fm_git_identity fmtest fmtest@example.invalid

# A clone whose origin names a forge host, so the project-identity comparison
# has something to contradict. The host and owner below are this repository's
# own registered origin, which is what makes the foreign-project case real.
make_project() {  # <dir>
  fm_git_init_commit "$1"
  git -C "$1" remote add origin https://github.com/kunchenguid/firstmate.git
}

state_dir() {  # <name>
  mkdir -p "$TMP_ROOT/$1"
  printf '%s\n' "$TMP_ROOT/$1"
}

# The merge path's own landed proof, written exactly as bin/fm-pr-lib.sh writes
# it, so the test exercises the real marker rather than a stand-in.
write_merge_marker() {  # <state> <id> <provider> <host> <path> <number>
  printf '%s\n%s\n%s\n%s\n%s\n' fm-pr-poll-merge-notified-v1 "$3" "$4" "$5" "$6" \
    > "$1/$2.pr-poll-merge-notified"
  chmod 600 "$1/$2.pr-poll-merge-notified"
}

# --- origin and URL identity --------------------------------------------------

test_origin_identity_accepts_every_clone_shape() {
  local repo got
  repo="$TMP_ROOT/shape-repo"
  fm_git_init_commit "$repo"
  git -C "$repo" remote add origin file://"$TMP_ROOT/local-repo.origin.git"
  for remote in \
    'https://github.com/kunchenguid/firstmate.git' \
    'https://github.com/kunchenguid/firstmate' \
    'git@github.com:kunchenguid/firstmate.git' \
    'ssh://git@github.com/kunchenguid/firstmate.git' \
    'ssh://git@github.com:2222/kunchenguid/firstmate.git'; do
    git -C "$repo" remote set-url origin "$remote"
    got=$(fm_done_url_origin_identity "$repo")
    [ "$got" = 'github.com/kunchenguid/firstmate' ] \
      || fail "origin $remote reduced to '$got', not the repository identity"
  done
  pass "every clone shape reduces to one repository identity"
}

test_origin_without_a_forge_host_has_no_identity() {
  local repo
  repo="$TMP_ROOT/local-repo"
  fm_git_init_commit "$repo"
  fm_done_url_origin_identity "$repo" \
    && fail "a local path origin was given a forge identity to compare against"
  pass "a local path origin carries no identity to contradict"
}

test_pull_request_url_is_readable_on_any_host() {
  local url
  for url in \
    'https://github.com/kunchenguid/firstmate/pull/7' \
    'https://git.example.com/group/sub/proj/-/merge_requests/12' \
    'https://review.example.com/c/platform/core/+/345'; do
    fm_done_url_endpoint_identity "$url" >/dev/null \
      || fail "pull request shape $url was not recognised on its host"
  done
  fm_done_url_endpoint_identity 'https://example.test/o/r/issues/7' >/dev/null 2>&1 \
    && fail "an issue URL was read as a pull request"
  pass "a pull request is readable on any host, and an issue is not one"
}

test_url_is_found_wherever_the_done_note_carries_it() {
  local note
  for note in \
    'PR https://github.com/kunchenguid/firstmate/pull/7 checks green' \
    'PR https://github.com/kunchenguid/firstmate/pull/7 checks green, risk low' \
    'PR https://github.com/kunchenguid/firstmate/pull/7 (checks green)' \
    'all rebased, see https://github.com/kunchenguid/firstmate/pull/7.' \
    '[key=fix] PR https://github.com/kunchenguid/firstmate/pull/7'; do
    [ "$(fm_done_url_from_note "$note")" = 'https://github.com/kunchenguid/firstmate/pull/7' ] \
      || fail "the pull request was not read off the note: $note"
  done
  fm_done_url_from_note 'steer shipped on fm/orbbot-steer-into-running-turn-a1 (d269b60)' >/dev/null 2>&1 \
    && fail "a completion naming only a branch was read as naming a pull request"
  pass "the pull request is read wherever the done note carries it"
}

# --- the status append path ---------------------------------------------------

test_status_done_without_a_url_is_refused() {
  local project reason rc
  project="$TMP_ROOT/status-project"
  make_project "$project"
  # The shape state/orbbot-steer-into-running-turn-a1.status line 3 recorded: a
  # completion naming its branch and commits, with the work only in its own copy.
  reason=$(fm_done_url_status_refusal ship no-mistakes \
    'steer shipped on fm/orbbot-steer-into-running-turn-a1 (d269b60, fe8e26c)' "$project")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a done reporting completion with no pull-request URL was accepted"
  case "$reason" in
    *"no pull-request URL"*) ;;
    *) fail "the refusal did not name what is missing: $reason" ;;
  esac
  pass "a done reporting completion with no pull-request URL is refused"
}

test_status_done_with_a_foreign_repository_url_is_refused() {
  local project reason rc
  project="$TMP_ROOT/foreign-project"
  make_project "$project"
  reason=$(fm_done_url_status_refusal ship direct-PR \
    'PR https://github.com/someone-else/other-repo/pull/9' "$project")
  rc=$?
  [ "$rc" -eq 1 ] || fail "a done naming another repository's pull request was accepted"
  case "$reason" in
    *"not a pull request on the registered project"*) ;;
    *) fail "the foreign-project refusal did not say why: $reason" ;;
  esac
  # A different owner on the same host, and the same owner in a different
  # repository, are each a different repository and each refused.
  for url in \
    'https://github.com/other-owner/firstmate/pull/9' \
    'https://github.com/kunchenguid/other-repo/pull/9'; do
    fm_done_url_status_refusal ship direct-PR "PR $url" "$project" >/dev/null \
      && fail "a done naming $url was accepted as this project's delivery"
  done
  pass "a done naming another repository's pull request is refused"
}

test_status_done_on_its_own_project_is_accepted() {
  local project
  project="$TMP_ROOT/own-project"
  make_project "$project"
  for note in \
    'PR https://github.com/kunchenguid/firstmate/pull/7 checks green' \
    'PR https://github.com/kunchenguid/firstmate/pull/7 - checks green' \
    'checks green: PR https://github.com/kunchenguid/firstmate/pull/7'; do
    fm_done_url_status_refusal ship no-mistakes "$note" "$project" \
      || fail "this project's own completion was refused: $note"
  done
  pass "a done naming this project's own pull request is accepted"
}

test_status_local_only_needs_no_url() {
  local project
  project="$TMP_ROOT/local-only-project"
  make_project "$project"
  fm_done_url_status_refusal ship local-only "ready in branch fm/local-only-a1" "$project" \
    || fail "a local-only completion was refused for naming no pull request"
  pass "a local-only completion is accepted with no pull-request URL"
}

test_status_scout_and_non_ship_lines_are_untouched() {
  local project
  project="$TMP_ROOT/scout-project"
  make_project "$project"
  fm_done_url_status_refusal scout no-mistakes 'report complete at 1816 lines' "$project" \
    || fail "a scout's report completion was gated on a pull request"
  pass "a scout's report completion is not gated on a pull request"
}

# --- the backlog done transition ---------------------------------------------
#
# Every case below uses a live worktree directory, because a task whose copy is
# gone is a different thing entirely and has its own case at the end of this
# section. WORKTREE is that live copy.
WORKTREE=
live_worktree() {
  [ -n "$WORKTREE" ] && return 0
  WORKTREE="$TMP_ROOT/live-worktree"
  mkdir -p "$WORKTREE"
}

test_backlog_done_without_a_url_is_refused() {
  local project state reason rc
  project="$TMP_ROOT/backlog-project"
  state=$(state_dir backlog-state)
  live_worktree
  make_project "$project"
  reason=$(fm_done_url_backlog_refusal ship no-mistakes '' 0 "$project" "$WORKTREE" "$state" task1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a Done row with no pull-request URL was allowed"
  case "$reason" in
    *"no pull-request URL"*) ;;
    *) fail "the refusal did not name what is missing: $reason" ;;
  esac
  ! fm_done_url_backlog_refusal ship direct-PR '' 0 "$project" "$WORKTREE" "$state" task1 \
    || fail "a direct-PR Done row with no pull-request URL was allowed"
  pass "a Done row with no pull-request URL is refused while nothing is proved landed"
}

test_backlog_local_only_needs_no_url() {
  local project state
  project="$TMP_ROOT/backlog-local-project"
  state=$(state_dir backlog-local-state)
  live_worktree
  make_project "$project"
  fm_done_url_backlog_refusal ship local-only '' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a local-only Done row was refused for naming no pull request"
  pass "a local-only Done row is accepted with no pull-request URL"
}

test_backlog_foreign_repository_url_is_refused() {
  local project state
  project="$TMP_ROOT/backlog-foreign-project"
  state=$(state_dir backlog-foreign-state)
  live_worktree
  make_project "$project"
  ! fm_done_url_backlog_refusal ship direct-PR \
    'https://github.com/someone-else/other-repo/pull/9' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a Done row naming another repository's pull request was allowed"
  pass "a Done row naming another repository's pull request is refused"
}

test_backlog_open_pull_request_is_refused_until_landed_is_proven() {
  local project state reason rc
  project="$TMP_ROOT/backlog-open-project"
  state=$(state_dir backlog-open-state)
  live_worktree
  make_project "$project"
  # No caller-supplied proof and no merge marker: this pull request could still
  # be open, and a Done must mean landed rather than "I pushed something".
  reason=$(fm_done_url_backlog_refusal ship no-mistakes \
    'https://github.com/kunchenguid/firstmate/pull/7' 0 "$project" "$WORKTREE" "$state" task1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "a Done row naming an unproven pull request was allowed"
  case "$reason" in
    *"not recorded as landed"*) ;;
    *) fail "the open-pull-request refusal did not say why: $reason" ;;
  esac
  # The caller's own landed-work test, which the merge path already performs.
  fm_done_url_backlog_refusal ship no-mistakes \
    'https://github.com/kunchenguid/firstmate/pull/7' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a Done row was refused although the caller proved landing"
  # Or the merge path's own durable record of the merge.
  write_merge_marker "$state" task1 github github.com kunchenguid/firstmate 7
  fm_done_url_backlog_refusal ship direct-PR \
    'https://github.com/kunchenguid/firstmate/pull/7' 0 "$project" "$WORKTREE" "$state" task1 \
    || fail "a Done row was refused although the merge marker proves the merge"
  # A merge recorded for a different pull request proves nothing about this one.
  ! fm_done_url_backlog_refusal ship direct-PR \
    'https://github.com/kunchenguid/firstmate/pull/8' 0 "$project" "$WORKTREE" "$state" task1 \
    || fail "a merge marker for pull request 7 covered pull request 8"
  pass "a Done naming an open pull request is refused unless landing is proven"
}

test_backlog_landed_own_pull_request_is_accepted() {
  local project state
  project="$TMP_ROOT/backlog-landed-project"
  state=$(state_dir backlog-landed-state)
  live_worktree
  make_project "$project"
  fm_done_url_backlog_refusal ship no-mistakes \
    'https://github.com/kunchenguid/firstmate/pull/7' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a landed Done row naming this project's own pull request was refused"
  pass "a landed Done row naming this project's own pull request is accepted"
}

test_backlog_unaddressable_url_is_refused() {
  local project state
  project="$TMP_ROOT/backlog-badurl-project"
  state=$(state_dir backlog-badurl-state)
  live_worktree
  make_project "$project"
  ! fm_done_url_backlog_refusal ship direct-PR 'not-a-url' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a Done row naming something other than a pull request was allowed"
  pass "a Done row naming something other than a pull request is refused"
}

# A record that carries no pull-request URL is honest only when there is nothing
# for one to be hiding: the caller has already proved the work is landed. A
# branch that is merely pushed, or that exists only in the disposable copy, is
# refused - that is the class the sourced rows above came from.
test_backlog_done_without_a_url_needs_landed_proof() {
  local project state live
  project="$TMP_ROOT/backlog-nourl-project"
  state=$(state_dir backlog-nourl-state)
  live="$TMP_ROOT/nourl-live-worktree"
  mkdir -p "$live"
  make_project "$project"
  fm_done_url_backlog_refusal ship no-mistakes '' 1 "$project" "$live" "$state" task1 \
    || fail "a Done row with no URL was refused although the caller proved the work landed"
  ! fm_done_url_backlog_refusal ship no-mistakes '' 0 "$project" "$live" "$state" task1 \
    || fail "a Done row with no URL was accepted with nothing proved landed"
  pass "a Done row with no URL is accepted only on proved landing"
}

# A task whose copy is gone and whose endpoint is gone has no branch and no
# commit anywhere, so a Done row is retiring a dead leftover rather than
# claiming a delivery. Refusing it would strand the record and protect nothing,
# which is why it is the one exemption besides local-only and a scout's report.
test_backlog_task_with_no_surviving_copy_still_retires() {
  local project state gone
  project="$TMP_ROOT/backlog-gone-project"
  state=$(state_dir backlog-gone-state)
  gone="$TMP_ROOT/gone-worktree"
  make_project "$project"
  [ ! -d "$gone" ] || fail "the no-surviving-copy fixture directory exists"
  fm_done_url_backlog_refusal ship no-mistakes '' 0 "$project" "$gone" "$state" task1 \
    || fail "a dead leftover with no surviving copy was refused for naming no pull request"
  # The exemption is only about the missing URL. A pull request that IS recorded
  # is still held to the registered project and to landing.
  ! fm_done_url_backlog_refusal ship no-mistakes \
    'https://github.com/someone-else/other-repo/pull/9' 1 "$project" "$gone" "$state" task1 \
    || fail "a recorded foreign pull request was accepted for a task with no surviving copy"
  pass "a task with no surviving copy still retires, but its recorded pull request is still checked"
}

test_unverifiable_project_never_refuses_on_no_evidence() {
  local project state
  project="$TMP_ROOT/unverifiable-project"
  fm_git_init_commit "$project"
  git -C "$project" remote add origin "$TMP_ROOT/unverifiable-project.origin.git"
  state=$(state_dir unverifiable-state)
  live_worktree
  # The clone names no forge host, so a URL cannot be shown to be foreign. The
  # landed requirement still applies; the project requirement does not invent a
  # mismatch that is not there.
  fm_done_url_backlog_refusal ship direct-PR \
    'https://github.com/kunchenguid/firstmate/pull/7' 1 "$project" "$WORKTREE" "$state" task1 \
    || fail "a Done was refused although the project carries no identity to contradict"
  pass "a project with no forge identity is never refused for a URL mismatch"
}

test_scout_done_row_needs_no_pull_request() {
  local project state
  project="$TMP_ROOT/backlog-scout-project"
  state=$(state_dir backlog-scout-state)
  live_worktree
  make_project "$project"
  fm_done_url_backlog_refusal scout no-mistakes '' 0 "$project" "$WORKTREE" "$state" scout1 \
    || fail "a scout's Done row was refused for naming no pull request"
  pass "a scout's Done row needs no pull request"
}

test_origin_identity_accepts_every_clone_shape
test_origin_without_a_forge_host_has_no_identity
test_pull_request_url_is_readable_on_any_host
test_url_is_found_wherever_the_done_note_carries_it
test_status_done_without_a_url_is_refused
test_status_done_with_a_foreign_repository_url_is_refused
test_status_done_on_its_own_project_is_accepted
test_status_local_only_needs_no_url
test_status_scout_and_non_ship_lines_are_untouched
test_backlog_done_without_a_url_is_refused
test_backlog_local_only_needs_no_url
test_backlog_foreign_repository_url_is_refused
test_backlog_open_pull_request_is_refused_until_landed_is_proven
test_backlog_landed_own_pull_request_is_accepted
test_backlog_unaddressable_url_is_refused
test_backlog_done_without_a_url_needs_landed_proof
test_backlog_task_with_no_surviving_copy_still_retires
test_unverifiable_project_never_refuses_on_no_evidence
test_scout_done_row_needs_no_pull_request
printf 'all fm-done-url-lib tests passed\n'