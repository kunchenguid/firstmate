#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's intake duplicate-work overlap scan.
#
# The headline case is a replay of a recorded live incident: one fix was
# implemented twice, under two task ids, on two branches, by two workers, with
# an open pull request already carrying the change, and nothing detected it.
# Every fixture below is that incident's real shape - the open task
# merge-refuses-unverified-green, its branch, and pull request 1614 - so the
# replay is red against any build without the scan by construction.
#
# The spawns run against a fake tmux pane and a fake gh-axi, so no harness,
# terminal, or forge is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-overlap)

# The recorded incident, verbatim.
DUP_TASK=merge-refuses-unverified-green
DUP_TITLE='refuse merges without verified green checks'
DUP_BRANCH=fm/merge-refuses-unverified-green
DUP_PR=1614
DUP_PR_TITLE='fix(bin): refuse merges without verified green checks'
NEW_TASK=merge-path-verifies-no-ci-green
UNRELATED_TASK=posix-launcher-platform-surface

# --- fixtures ---------------------------------------------------------------

# A gh-axi whose `pr list` prints the TOON block the real one prints, or fails
# the way an unreachable or unauthenticated forge fails. FM_FAKE_GH_FAIL
# selects the outage.
make_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = pr ] && [ "${2:-}" = list ]; then
  if [ -n "${FM_FAKE_GH_FAIL:-}" ]; then
    echo "error: could not reach github.com: dial tcp: lookup github.com: no such host" >&2
    exit 1
  fi
  cat <<'TOON'
count: 2 of 523 total
pull_requests[2]{number,title,state,author,draft,review}:
  1614,"fix(bin): refuse merges without verified green checks",open,someone,no,none
  1885,"Make filed work reach the captain by name, not just the record",open,other,no,none
help[1]:
  Run `gh-axi pr view <number>` to view details
TOON
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
}

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" pi pi-signed
  make_fake_gh "$fakebin"
  printf '%s\n' "$fakebin"
}

# A home carrying the incident's open task, its branch, and (through the fake
# gh-axi above) its open pull request.
make_case() {  # <name> <spawned-id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'pi\n' > "$home/config/crew-harness"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  git -C "$proj" branch "$DUP_BRANCH" >/dev/null 2>&1
  cat > "$home/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] $DUP_TASK - $DUP_TITLE (repo: alpha) (kind: ship) (since 2026-08-05)
  Two composing defects found by an earlier sweep: an empty check-run set reads
  as green, and the landing path verifies nothing before it lands.

## Queued
- [ ] unrelated-doc-audience-sweep - Reclassify the documentation audience inventory (repo: alpha) (kind: ship)
  Nothing to do with landing or check runs.

## Done
- [x] $NEW_TASK-old - a closed record naming merges and green checks that must never be surfaced (repo: alpha)
EOF
  mkdir -p "$home/data/$id"
  printf '# Task\n%s\n' "${3:-brief for $id}" > "$home/data/$id/brief.md"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {  # <home> <wt> <fakebin> <spawn args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    GROK_HOME="$home/grok-home" PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" --mode no-mistakes --yolo off 2>&1
}

# --- the replay -------------------------------------------------------------

test_replay_surfaces_the_recorded_duplicate() {
  local rec out status meta
  rec=$(make_case replay "$NEW_TASK")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "advisory mode must surface the overlap without refusing the spawn"

  assert_contains "$out" "overlap=candidates" "the replay did not report a candidate overlap"
  assert_contains "$out" "task,$DUP_TASK," "the open task already covering this work was not surfaced"
  assert_contains "$out" "branch,$DUP_BRANCH," "the live branch already covering this work was not surfaced"
  assert_contains "$out" "pr,$DUP_PR,\"$DUP_PR_TITLE\"" \
    "the open pull request already covering this work was not surfaced with the title that makes it reviewable"
  assert_contains "$out" "green" "the shared tokens that make the overlap reviewable were not reported"
  assert_not_contains "$out" "overlap=none" "a live overlap must never be reported as none"
  # The closed backlog record names the same words on purpose: a landed task is
  # not work in flight and surfacing it would train the reader to skim.
  assert_not_contains "$out" "$NEW_TASK-old" "a closed backlog record was surfaced as open work"
  # The unrelated open item shares no subject tokens and must stay out of the set.
  assert_not_contains "$out" "unrelated-doc-audience-sweep" "an unrelated open task was surfaced"

  meta="$HOME_DIR/state/$NEW_TASK.meta"
  assert_grep "overlap=candidates" "$meta" "the spawn record does not carry the overlap result"
  assert_grep "task:$DUP_TASK" "$meta" "the spawn record does not name the overlapping task"
  assert_grep "branch:$DUP_BRANCH" "$meta" "the spawn record does not name the overlapping branch"
  assert_grep "pr:$DUP_PR" "$meta" "the spawn record does not name the overlapping pull request"
  pass "replaying the recorded incident surfaces the duplicate task, branch, and pull request"
}

test_unrelated_task_surfaces_no_overlap() {
  local rec out status meta
  rec=$(make_case negative-control "$UNRELATED_TASK")
  read_case_record "$rec"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$UNRELATED_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an unrelated task must spawn"
  assert_contains "$out" "overlap=none" "the negative control did not report an empty overlap set"
  assert_not_contains "$out" "$DUP_TASK" "the negative control matched work it shares no subject with"
  assert_not_contains "$out" "$DUP_BRANCH" "the negative control matched a branch it shares no subject with"

  meta="$HOME_DIR/state/$UNRELATED_TASK.meta"
  assert_grep "overlap=none" "$meta" "the spawn record does not distinguish a checked-and-empty set"
  assert_no_grep "overlap_refs=" "$meta" "an empty overlap set must record no refs"
  pass "an unrelated task surfaces no overlap and records the empty set as checked"
}

# --- the empty-set law ------------------------------------------------------

test_forge_outage_is_unavailable_not_none() {
  local rec out status meta
  rec=$(make_case forge-outage "$UNRELATED_TASK")
  read_case_record "$rec"

  # The unrelated task is deliberate: with a reachable forge this same fixture
  # reports overlap=none, so the only thing under test is the outage.
  out=$(FM_FAKE_GH_FAIL=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$UNRELATED_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "advisory mode must not refuse on an unreachable forge"
  assert_contains "$out" "overlap=unavailable" "an unreachable forge was not reported as unavailable"
  assert_not_contains "$out" "overlap=none" "an unreachable forge must never read as an empty overlap set"
  assert_contains "$out" "unavailable,pr," "the unreadable source was not named"

  meta="$HOME_DIR/state/$UNRELATED_TASK.meta"
  assert_grep "overlap=unavailable" "$meta" "the spawn record does not preserve the incomplete set"
  assert_no_grep "overlap=none" "$meta" "the spawn record downgraded an incomplete set to a pass"
  pass "an unreachable forge yields overlap=unavailable and never overlap=none"
}

test_truncated_pr_listing_is_unavailable_not_none() {
  local rec out status meta
  rec=$(make_case pr-window "$UNRELATED_TASK")
  read_case_record "$rec"

  # The fake gh-axi's count header reports 523 open in total, so a two-row
  # window is a bounded look at a larger open set. The unrelated task is
  # deliberate: with a window covering the whole total this same fixture
  # reports overlap=none, so the only thing under test is the truncation.
  out=$(FM_SPAWN_OVERLAP_PR_LIMIT=2 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$UNRELATED_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "advisory mode must not refuse on a truncated listing"
  assert_contains "$out" "overlap=unavailable" "a truncated pull request listing was not reported as unavailable"
  assert_not_contains "$out" "overlap=none" "a truncated listing must never read as an empty overlap set"
  assert_contains "$out" "unavailable,pr," "the truncated source was not named"
  assert_contains "$out" "523" "the reason did not name the forge's reported open total"

  meta="$HOME_DIR/state/$UNRELATED_TASK.meta"
  assert_grep "overlap=unavailable" "$meta" "the spawn record does not preserve the incomplete set"
  assert_no_grep "overlap=none" "$meta" "the spawn record downgraded a truncated listing to a pass"
  pass "a pull request listing smaller than the forge's open total yields overlap=unavailable and never overlap=none"
}

test_missing_forge_cli_is_unavailable_not_none() {
  local rec out fakebin
  rec=$(make_case forge-missing "$UNRELATED_TASK")
  read_case_record "$rec"
  # Remove the fake and shadow the real one with a PATH holding neither, so the
  # CLI is genuinely absent rather than failing.
  rm -f "$FAKEBIN_DIR/gh-axi"
  fakebin="$CASE_DIR/isolated-bin"
  mkdir -p "$fakebin"
  cp "$FAKEBIN_DIR"/* "$fakebin/" 2>/dev/null || true

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    GROK_HOME="$HOME_DIR/grok-home" PATH="$fakebin:/usr/bin:/bin" \
    "$SPAWN" "$UNRELATED_TASK" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)

  assert_contains "$out" "overlap=unavailable" "an absent forge CLI was not reported as unavailable"
  assert_not_contains "$out" "overlap=none" "an absent forge CLI must never read as an empty overlap set"
  pass "an absent forge CLI yields overlap=unavailable and never overlap=none"
}

# --- enforcement ------------------------------------------------------------

test_enforce_requires_acknowledgement_and_records_it() {
  local rec out status meta refs
  rec=$(make_case enforce "$NEW_TASK")
  read_case_record "$rec"
  printf 'enforce\n' > "$HOME_DIR/config/spawn-overlap"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "enforce mode must refuse an unacknowledged live overlap"
  assert_contains "$out" "would dispatch against work already open" "the refusal did not name its reason"
  assert_contains "$out" "task:$DUP_TASK" "the refusal did not name the unacknowledged task"
  assert_contains "$out" "--overlap-ack" "the refusal did not name the way through"
  assert_absent "$HOME_DIR/state/$NEW_TASK.meta" "a refused spawn must leave no task metadata behind"

  # The refusal prints the exact acknowledgement to reuse; take it from there
  # rather than reconstructing it, which is how firstmate would use it.
  refs=$(printf '%s\n' "$out" | sed -n "s/.*--overlap-ack '\\([^']*\\)'.*/\\1/p" | head -n 1)
  [ -n "$refs" ] || fail "the refusal did not print a reusable --overlap-ack value"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR" --overlap-ack "$refs")
  status=$?
  expect_code 0 "$status" "an explicit acknowledgement must let the dispatch through"
  meta="$HOME_DIR/state/$NEW_TASK.meta"
  assert_grep "overlap=candidates" "$meta" "the acknowledged spawn record lost the overlap result"
  assert_grep "overlap_ack=" "$meta" "the acknowledgement was not recorded in the spawn record"
  assert_contains "$(cat "$meta")" "overlap_ack=$refs" "the recorded acknowledgement does not match what was given"
  pass "enforce mode refuses an unacknowledged live overlap and records the acknowledgement that clears it"
}

test_enforce_refuses_an_incomplete_set_without_acknowledgement() {
  local rec out status
  rec=$(make_case enforce-outage "$UNRELATED_TASK")
  read_case_record "$rec"
  printf 'enforce\n' > "$HOME_DIR/config/spawn-overlap"

  out=$(FM_FAKE_GH_FAIL=1 run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$UNRELATED_TASK" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "an incomplete overlap set must not pass as an empty one"
  assert_contains "$out" "unavailable:pr" "the refusal did not name the source that could not be read"
  pass "enforce mode refuses an incomplete overlap set, because an absent set is not a pass"
}

test_advisory_default_never_refuses() {
  local rec out status
  rec=$(make_case advisory-default "$NEW_TASK")
  read_case_record "$rec"
  assert_absent "$HOME_DIR/config/spawn-overlap" "the default case must carry no overlap config"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "the default posture must print and record without refusing"
  assert_contains "$out" "overlap=candidates" "the default posture went silent on a live overlap"
  pass "the default posture is loud and never a refusal"
}

test_off_skips_the_scan_but_says_so() {
  local rec out status meta
  rec=$(make_case switched-off "$NEW_TASK")
  read_case_record "$rec"
  printf 'off\n' > "$HOME_DIR/config/spawn-overlap"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "an opted-out home must still spawn"
  assert_contains "$out" "overlap=off" "opting out was silent"
  assert_not_contains "$out" "overlap=none" "an unscanned task must never read as a checked-and-empty one"
  meta="$HOME_DIR/state/$NEW_TASK.meta"
  assert_grep "overlap=off" "$meta" "the spawn record does not distinguish an unscanned task"
  pass "off skips the scan and records that nothing was compared"
}

test_misspelled_config_value_refuses() {
  local rec out status
  rec=$(make_case bad-config "$NEW_TASK")
  read_case_record "$rec"
  printf 'advisery\n' > "$HOME_DIR/config/spawn-overlap"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "a safety knob that cannot be read must refuse"
  assert_contains "$out" "config/spawn-overlap" "the refusal did not name the file to fix"
  assert_absent "$HOME_DIR/state/$NEW_TASK.meta" "a refused spawn must leave no task metadata behind"
  pass "a misspelled overlap config value refuses instead of reading as absent"
}

test_unreadable_config_file_refuses() {
  local rec out status
  rec=$(make_case unreadable-config "$NEW_TASK")
  read_case_record "$rec"
  if [ "$(id -u)" = 0 ]; then
    pass "skipped: running as root ignores the unreadable-config permission bits"
    return 0
  fi
  # The knob is set to enforce and then made unreadable: absent stays advisory,
  # but PRESENT and unreadable must refuse rather than silently downgrade.
  printf 'enforce\n' > "$HOME_DIR/config/spawn-overlap"
  chmod 000 "$HOME_DIR/config/spawn-overlap"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  status=$?
  chmod 644 "$HOME_DIR/config/spawn-overlap"
  expect_code 1 "$status" "a present but unreadable safety knob must refuse"
  assert_contains "$out" "config/spawn-overlap" "the refusal did not name the file to fix"
  assert_contains "$out" "cannot be read" "the refusal did not say why"
  assert_absent "$HOME_DIR/state/$NEW_TASK.meta" "a refused spawn must leave no task metadata behind"
  pass "a present but unreadable overlap config refuses instead of reading as absent"
}

# --- sources ----------------------------------------------------------------

test_live_task_without_a_backlog_row_is_surfaced() {
  local rec out
  rec=$(make_case live-meta-only "$NEW_TASK")
  read_case_record "$rec"
  # A task under way whose backlog row was never written: the durable queue
  # cannot see it, and it is exactly as duplicable as one that has a row.
  fm_write_meta "$HOME_DIR/state/merge-green-verifier-live.meta" \
    "window=firstmate:fm-merge-green-verifier-live" \
    "worktree=$WT_DIR" "project=$PROJ_DIR" "harness=pi" "kind=ship"
  # A persistent second mate is a home, not a work item, and must not be
  # surfaced as overlapping work however its name reads.
  fm_write_secondmate_meta "$HOME_DIR/state/merge-green-secondmate.meta" "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  assert_contains "$out" "task,merge-green-verifier-live," "a task under way with no backlog row was invisible"
  assert_not_contains "$out" "merge-green-secondmate" "a persistent second mate was surfaced as overlapping work"
  pass "a task under way with no backlog row is surfaced, and a second mate is not"
}

test_a_branch_merely_ending_with_the_task_id_stays_visible() {
  local rec out
  rec=$(make_case branch-boundary "$NEW_TASK")
  read_case_record "$rec"
  # Only the task's OWN branch is excluded from the scan, on a path-component
  # boundary. A branch that merely ends with the id - a retry or follow-up of
  # the same work family - is the strongest evidence of a duplicate.
  git -C "$PROJ_DIR" branch "fm/re-$NEW_TASK" >/dev/null 2>&1

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  assert_contains "$out" "branch,fm/re-$NEW_TASK," \
    "a branch that merely ends with the task id was hidden as if it were the task's own branch"
  pass "a branch that merely ends with the task id stays visible to the scan"
}

# --- what separates a candidate from a coincidence --------------------------

# A shared-token floor alone is not a filter in a fleet whose work all shares
# one house vocabulary: measured against a real backlog it surfaced 61
# candidates for a single task, and a set nobody can read is a set nobody
# reads. A candidate must also cover half of the smaller of the two
# vocabularies. Both halves of that rule are load-bearing and are asserted here
# together, because relaxing either one silently is what would make the scan
# decorative.
test_a_long_subject_keeps_short_branches_and_drops_coincidences() {
  local rec out subject
  subject='The landing path merges without verifying that continuous integration is green.'
  rec=$(make_case ratio "$NEW_TASK" "$subject")
  read_case_record "$rec"
  # A task with a large, unrelated vocabulary that happens to name two of the
  # subject's words. Two shared tokens clear the floor and must not be enough.
  cat >> "$HOME_DIR/data/backlog.md" <<'EOF'
- [ ] engraphis-thumbnail-cache-eviction - Add an LRU eviction policy to the Engraphis thumbnail cache (repo: engraphis) (kind: ship)
  The cache grows without bound across imports. Size it by resident bytes,
  evict least-recently-used entries first, and expose the high-water mark.
  Unrelated aside: the release notes were merged while the dashboard was green.
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  assert_contains "$out" "task,$DUP_TASK," "the genuine duplicate was lost once the subject grew"
  # Four words against a subject of eight: denominating by the subject alone
  # would put every branch permanently out of reach.
  assert_contains "$out" "branch,$DUP_BRANCH," "a short branch name was unreachable from a long subject"
  assert_not_contains "$out" "engraphis-thumbnail-cache-eviction" \
    "a coincidental two-word overlap with an unrelated task was surfaced as a candidate"
  pass "a long subject still reaches short branch names and no longer matches coincidences"
}

test_strongest_evidence_is_listed_first() {
  local rec out first
  rec=$(make_case ranking "$NEW_TASK")
  read_case_record "$rec"
  # The weaker match is deliberately written FIRST in the backlog, so source
  # order and evidence order disagree and only real ranking can pass this.
  cat > "$HOME_DIR/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] green-release-notes - Collect the green release notes after each merge (repo: alpha) (kind: ship)
  Nothing to do with verifying anything.
- [ ] $DUP_TASK - $DUP_TITLE (repo: alpha) (kind: ship) (since 2026-08-05)
  An empty check-run set reads as green, and the landing path verifies nothing.
EOF

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$NEW_TASK" "$PROJ_DIR")
  assert_contains "$out" "green-release-notes" "the weaker candidate was filtered out, so this proves nothing about order"
  first=$(printf '%s\n' "$out" | sed -n 's/^  \(task\|branch\|pr\),.*/&/p' | head -n 1)
  assert_contains "$first" "$DUP_TASK" \
    "the strongest candidate was not listed first, so the likeliest duplicate is not what gets read"
  pass "candidates are listed strongest evidence first, not in the order the sources were read"
}

# --- the shared forge reader ------------------------------------------------

test_forge_reader_separates_no_rows_from_no_answer() {
  local dir fakebin out status
  dir="$TMP_ROOT/forge-reader"
  fakebin=$(make_fakebin "$dir/fake")
  mkdir -p "$dir/repo"

  out=$(PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_open_request_titles "$2" 600' _ "$ROOT" "$dir/repo")
  status=$?
  expect_code 0 "$status" "a reachable forge must return success"
  assert_contains "$out" "1614" "the listing dropped the pull request number"
  assert_contains "$out" "refuse merges without verified green checks" "the listing dropped the title"
  # A title carrying a comma must survive intact, or a later field would be
  # read as part of it.
  assert_contains "$out" "Make filed work reach the captain by name, not just the record" \
    "a comma inside a title truncated it"

  out=$(PATH="$fakebin:$PATH" FM_FAKE_GH_FAIL=1 bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_open_request_titles "$2" 600; echo "rc=$?"; echo "err=$FM_PR_LIST_ERROR"' _ "$ROOT" "$dir/repo")
  assert_contains "$out" "rc=1" "an unreachable forge returned success"
  assert_contains "$out" "err=" "an unreachable forge reported no reason"
  assert_not_contains "$out" "1614" "a failed listing must yield no rows at all"

  # A window smaller than the forge's reported open total must fail the call,
  # naming both, and yield no rows: a truncated listing is not the open set.
  out=$(PATH="$fakebin:$PATH" bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_open_request_titles "$2" 2; echo "rc=$?"; echo "err=$FM_PR_LIST_ERROR"' _ "$ROOT" "$dir/repo")
  assert_contains "$out" "rc=1" "a truncated listing returned success"
  assert_contains "$out" "523" "the truncation reason did not name the forge's open total"
  assert_not_contains "$out" "1614" "a truncated listing must yield no rows at all"
  pass "the shared forge reader separates 'no open requests' from 'no answer' and from 'a bounded window'"
}

test_replay_surfaces_the_recorded_duplicate
test_unrelated_task_surfaces_no_overlap
test_forge_outage_is_unavailable_not_none
test_truncated_pr_listing_is_unavailable_not_none
test_missing_forge_cli_is_unavailable_not_none
test_enforce_requires_acknowledgement_and_records_it
test_enforce_refuses_an_incomplete_set_without_acknowledgement
test_advisory_default_never_refuses
test_off_skips_the_scan_but_says_so
test_misspelled_config_value_refuses
test_unreadable_config_file_refuses
test_live_task_without_a_backlog_row_is_surfaced
test_a_branch_merely_ending_with_the_task_id_stays_visible
test_a_long_subject_keeps_short_branches_and_drops_coincidences
test_strongest_evidence_is_listed_first
test_forge_reader_separates_no_rows_from_no_answer

echo "# all fm-spawn-overlap tests passed"
