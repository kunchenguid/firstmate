#!/usr/bin/env bash
# End-to-end tests for captain-held teardown, merge entrypoints, origin
# inventory, and archived-answer recovery. Core hold/answer/release coverage
# stays in fm-captain-hold-lifecycle.test.sh. Shared fixtures live in
# tests/captain-hold-helpers.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-hold-teardown)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# shellcheck source=tests/captain-hold-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/captain-hold-helpers.sh"


# The originating work item is itself the captain call, which is what the policy
# prefers ("hold the work item the question gates"). Cleanup of that finished
# work must never be the act that closes the captain's own row: the deliverable
# is recorded on the still-held row, the call keeps reading as open on the
# board, and only a recorded answer closes it. An ordinary finished task in the
# same home must still close exactly as before, and discard authority covers
# unlanded work, never the captain's question.
test_teardown_never_closes_a_captain_held_task() {
  local home id plain forced json show
  home=$(make_home teardown-held)
  id=sample-attach-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample attachment evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Sample attachment evidence\n\nThe captain must choose inline or by-reference attachments.\n' \
    > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" \
    --reason "captain must choose inline or by-reference attachments" >/dev/null \
    || fail "could not hold the originating work item for the captain"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed with the origin as its own captain call"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held investigation failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held row is gone after cleanup"
  assert_not_contains "$show" "state: done" \
    "cleanup closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "the finished work's row still reads as worked on"
  assert_contains "$show" "held: yes" "cleanup lifted the captain hold"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the deliverable was not recorded on the still-open row"
  assert_absent "$home/state/$id.meta" "cleanup did not release the finished worker record"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  assert_grep "still held for the captain" "$home/teardown.out" \
    "cleanup did not say the row stays open for the captain"
  json=$(run_bearings "$home") || fail "Bearings failed after cleanup of a captain-held task"
  printf '%s' "$json" | jq -e --arg id "$id" '
    (.decisions_open | any(.id == $id and .verb == "captain-hold"))
  ' >/dev/null || fail "the board no longer surfaces the captain call: $json"

  # The ordinary path is untouched: a finished task with no captain call closes.
  plain=sample-plain-review
  mkdir -p "$home/data/$plain"
  tasks_in "$home" add "$plain" "Investigate the sample cache" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the ordinary fixture"
  write_origin_meta "$home" "$plain"
  printf 'done: report complete\n' > "$home/state/$plain.status"
  printf '# Sample cache\n\nNothing waits on the captain.\n' > "$home/data/$plain/report.md"
  run_captain "$home" complete "$plain" --none >/dev/null \
    || fail "completion gate failed for the ordinary investigation"
  run_teardown "$home" "$plain" > "$home/plain.out" 2> "$home/plain.err" \
    || fail "ordinary cleanup failed: $(cat "$home/plain.err")"
  show=$(tasks_in "$home" show "$plain" --full) || fail "the ordinary row vanished"
  assert_contains "$show" "state: done" "ordinary cleanup no longer closes its backlog item"
  assert_contains "$show" "data/$plain/report.md" "ordinary cleanup lost the report link"
  assert_absent "$home/state/$plain.backlog-close" "ordinary cleanup left its pending close behind"

  # Discard authority covers unlanded work, never the captain's question.
  forced=sample-forced-review
  mkdir -p "$home/data/$forced"
  tasks_in "$home" add "$forced" "Investigate the sample forced path" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the forced fixture"
  write_origin_meta "$home" "$forced"
  printf 'done: report complete\n' > "$home/state/$forced.status"
  printf '# Sample forced path\n\nOne captain choice remains.\n' > "$home/data/$forced/report.md"
  run_captain "$home" hold "$forced" --reason "captain must choose the sample forced path" >/dev/null \
    || fail "could not hold the forced fixture for the captain"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$forced" --force \
    > "$home/forced.out" 2> "$home/forced.err" \
    || fail "forced cleanup failed: $(cat "$home/forced.err")"
  show=$(tasks_in "$home" show "$forced" --full) || fail "forced cleanup erased the captain-held row"
  assert_not_contains "$show" "state: done" \
    "discard authority closed a captain call with no recorded answer"
  assert_contains "$show" "state: queued" "forced cleanup left the captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "forced cleanup dropped the captain hold"

  # Only a recorded answer closes the captain call, and the deliverable survives it.
  printf 'Ship attachments by reference.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the surviving captain call could not be answered"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered row is gone"
  assert_contains "$show" "state: done" "the recorded answer did not close the captain call"
  assert_contains "$show" "Ship attachments by reference." "the captain's words were not recorded"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "the answer lost the recorded deliverable"
  pass "cleanup leaves a captain-held work item open with its deliverable, and only an answer closes it"
}

test_retained_row_artifacts_survive_captain_answers() {
  local home retained_id precedence_id rejected_id rejected_local_id report_question_id
  local approved_id released_id local_id answered_id reportless_scout_id legacy_id
  local repo wt
  local local_repo local_wt
  local precedence_pr rejected_pr approved_pr released_pr json show
  home=$(make_home retained-row-artifacts)
  perl -0pi -e 's/done_keep = 10/done_keep = 20/' "$home/.tasks.toml"
  retained_id=sample-retained-report
  mkdir -p "$home/data/$retained_id"
  tasks_in "$home" add "$retained_id" "Investigate retained report evidence" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the retained report fixture"
  write_origin_meta "$home" "$retained_id"
  printf 'done: report complete\n' > "$home/state/$retained_id.status"
  printf '# Retained report\n\nThe captain must choose the follow-up.\n' \
    > "$home/data/$retained_id/report.md"
  run_captain "$home" hold "$retained_id" --reason "captain must choose the report follow-up" \
    >/dev/null || fail "could not hold the retained report"
  complete_through_sibling "$home" "$retained_id" >/dev/null \
    || fail "completion gate failed for the retained report"
  run_teardown "$home" "$retained_id" > "$home/retained-teardown.out" \
    2> "$home/report-teardown.err" \
    || fail "retained report cleanup failed: $(cat "$home/report-teardown.err")"
  printf 'Proceed with the report follow-up.\n' > "$home/report-answer.txt"
  run_captain "$home" answer "$retained_id" --decision-file "$home/report-answer.txt" >/dev/null \
    || fail "could not answer the retained report call"

  precedence_id=sample-retained-report-pr-title
  precedence_pr=https://github.com/sample/sample/pull/21
  mkdir -p "$home/data/$precedence_id"
  tasks_in "$home" add "$precedence_id" "Investigate $precedence_pr regression" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the report precedence fixture"
  write_origin_meta "$home" "$precedence_id"
  printf 'done: report complete\n' > "$home/state/$precedence_id.status"
  printf '# Retained report with pull request context\n' \
    > "$home/data/$precedence_id/report.md"
  run_captain "$home" hold "$precedence_id" \
    --reason "captain must choose the report follow-up" >/dev/null \
    || fail "could not hold the report precedence fixture"
  complete_through_sibling "$home" "$precedence_id" >/dev/null \
    || fail "completion gate failed for the report precedence fixture"
  run_teardown "$home" "$precedence_id" > "$home/precedence-teardown.out" \
    2> "$home/precedence-teardown.err" \
    || fail "report precedence cleanup failed: $(cat "$home/precedence-teardown.err")"
  printf 'Proceed with the pull-request regression report.\n' \
    > "$home/precedence-answer.txt"
  run_captain "$home" answer "$precedence_id" \
    --decision-file "$home/precedence-answer.txt" >/dev/null \
    || fail "could not answer the report precedence call"
  show=$(tasks_in "$home" show "$precedence_id" --full) \
    || fail "the report precedence row disappeared"
  assert_contains "$show" "state: done" "the report precedence answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report precedence row lost its retained-scout evidence"

  rejected_id=sample-rejected-merge
  rejected_pr="https://github.com/sample/sample/pull/22"
  tasks_in "$home" add "$rejected_id" "Decide whether $rejected_pr may merge" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected merge fixture"
  run_captain "$home" hold "$rejected_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the rejected merge"
  printf 'Do not merge this pull request.\n' > "$home/rejected-answer.txt"
  run_captain "$home" answer "$rejected_id" --decision-file "$home/rejected-answer.txt" \
    >/dev/null || fail "could not record the rejected merge"
  show=$(tasks_in "$home" show "$rejected_id" --full) || fail "the rejected merge disappeared"
  assert_contains "$show" "state: done" "the rejected merge answer did not close its call"
  assert_contains "$show" "hold_kind: captain" "the rejected merge lost its non-release evidence"

  rejected_local_id=sample-rejected-local
  tasks_in "$home" add "$rejected_local_id" "Decide whether to land local main" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the rejected local fixture"
  run_captain "$home" hold "$rejected_local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the rejected local merge"
  printf 'Do not land this change locally.\n' > "$home/rejected-local-answer.txt"
  run_captain "$home" answer "$rejected_local_id" \
    --decision-file "$home/rejected-local-answer.txt" >/dev/null \
    || fail "could not record the rejected local merge"
  show=$(tasks_in "$home" show "$rejected_local_id" --full) \
    || fail "the rejected local merge disappeared"
  assert_contains "$show" "state: done" "the rejected local answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the rejected local merge lost its non-release evidence"

  report_question_id=sample-report-path-question
  tasks_in "$home" add "$report_question_id" \
    "Decide whether data/$report_question_id/report.md should be published" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the report-path question fixture"
  run_captain "$home" hold "$report_question_id" \
    --reason "captain report publication decision pending" >/dev/null \
    || fail "could not hold the report-path question"
  printf 'Do not publish this report.\n' > "$home/report-question-answer.txt"
  run_captain "$home" answer "$report_question_id" \
    --decision-file "$home/report-question-answer.txt" >/dev/null \
    || fail "could not record the report-path answer"
  show=$(tasks_in "$home" show "$report_question_id" --full) \
    || fail "the report-path question disappeared"
  assert_contains "$show" "state: done" "the report-path answer did not close its call"
  assert_contains "$show" "hold_kind: captain" \
    "the report-path question lost its non-release evidence"

  approved_id=sample-approved-merge
  approved_pr="https://github.com/sample/sample/pull/23"
  repo="$home/projects/sample-approved"
  wt="$home/projects/$approved_id"
  fm_git_worktree "$repo" "$wt" fm/approved-merge
  tasks_in "$home" add "$approved_id" "Ship the approved pull request $approved_pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the approved merge fixture"
  fm_write_meta "$home/state/$approved_id.meta" \
    "window=firstmate:fm-$approved_id" "endpoint_task_id=$approved_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$approved_pr" "spawn_gen=fixture-$approved_id"
  printf 'done: PR %s merged\n' "$approved_pr" > "$home/state/$approved_id.status"
  run_captain "$home" hold "$approved_id" --reason "captain merge approval pending" \
    >/dev/null || fail "could not hold the approved merge"
  printf 'Merge the approved pull request.\n' > "$home/approved-answer.txt"
  run_captain "$home" answer "$approved_id" --release \
    --decision-file "$home/approved-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$approved_id" --full) || fail "the approved merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" "merge approval retained its captain hold kind"
  run_teardown "$home" "$approved_id" > "$home/approved-teardown.out" \
    2> "$home/approved-teardown.err" \
    || fail "approved merge cleanup failed: $(cat "$home/approved-teardown.err")"

  local_id=sample-released-local
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'landed locally\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'local delivery'
  tasks_in "$home" add "$local_id" "Land the approved local-only change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'done: local merge ready\n' > "$home/state/$local_id.status"
  printf 'local_done_head=%s\n' "$(git -C "$local_wt" rev-parse HEAD)" >> "$home/state/$local_id.meta"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the released local merge"
  printf 'Land the approved change locally.\n' > "$home/local-answer.txt"
  run_captain "$home" answer "$local_id" --release \
    --decision-file "$home/local-answer.txt" >/dev/null \
    || fail "could not release the local merge"
  show=$(tasks_in "$home" show "$local_id" --full) || fail "the released local merge disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "local merge approval retained its captain hold kind"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local-merge.out" 2> "$home/local-merge.err" \
    || fail "approved local merge failed: $(cat "$home/local-merge.err")"
  run_teardown "$home" "$local_id" > "$home/local-teardown.out" \
    2> "$home/local-teardown.err" \
    || fail "released local cleanup failed: $(cat "$home/local-teardown.err")"

  released_id=sample-released-report
  released_pr=https://github.com/sample/sample/pull/24
  mkdir -p "$home/data/$released_id"
  tasks_in "$home" add "$released_id" "Investigate $released_pr report evidence" \
    --kind scout --repo sample --start >/dev/null \
    || fail "could not create the released report fixture"
  write_origin_meta "$home" "$released_id"
  printf 'done: report complete\n' > "$home/state/$released_id.status"
  printf '# Released report\n' > "$home/data/$released_id/report.md"
  run_captain "$home" hold "$released_id" --reason "captain report release pending" \
    >/dev/null || fail "could not hold the released report"
  complete_through_sibling "$home" "$released_id" >/dev/null \
    || fail "completion gate failed for the released report"
  printf 'Release the completed report.\n' > "$home/released-answer.txt"
  run_captain "$home" answer "$released_id" --release \
    --decision-file "$home/released-answer.txt" >/dev/null \
    || fail "could not release the completed report"
  run_teardown "$home" "$released_id" > "$home/released-teardown.out" \
    2> "$home/released-teardown.err" \
    || fail "released report cleanup failed: $(cat "$home/released-teardown.err")"

  answered_id=sample-artifactless-captain-answer
  tasks_in "$home" add "$answered_id" "Choose the artifactless route" --kind captain \
    --repo sample --start >/dev/null || fail "could not create the artifactless captain call"
  run_captain "$home" hold "$answered_id" --reason "captain route choice pending" \
    >/dev/null || fail "could not hold the artifactless captain call"
  printf 'Continue without a delivery artifact.\n' > "$home/artifactless-answer.txt"
  run_captain "$home" answer "$answered_id" --release \
    --decision-file "$home/artifactless-answer.txt" >/dev/null \
    || fail "could not release the artifactless captain call"
  tasks_in "$home" 'done' "$answered_id" >/dev/null \
    || fail "could not complete the released artifactless captain call"

  decision_local_id=sample-released-local-worded-decision
  tasks_in "$home" add "$decision_local_id" "Land the reviewed change" --kind ship \
    --repo sample --start >/dev/null \
    || fail "could not create the local-worded decision fixture"
  run_captain "$home" hold "$decision_local_id" --reason "captain landing route pending" \
    >/dev/null || fail "could not hold the local-worded decision fixture"
  printf 'local main\n' > "$home/local-worded-answer.txt"
  run_captain "$home" answer "$decision_local_id" --release \
    --decision-file "$home/local-worded-answer.txt" >/dev/null \
    || fail "could not release the local-worded decision fixture"
  tasks_in "$home" 'done' "$decision_local_id" >/dev/null \
    || fail "could not complete the local-worded decision fixture"

  reportless_scout_id=sample-reportless-scout
  tasks_in "$home" add "$reportless_scout_id" "Investigate without a report" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the reportless scout"
  tasks_in "$home" 'done' "$reportless_scout_id" >/dev/null \
    || fail "could not complete the reportless scout"

  legacy_id=sample-kindless-legacy-delivery
  tasks_in "$home" add "$legacy_id" "Complete the legacy work" --repo sample --start \
    >/dev/null || fail "could not create the kindless legacy delivery"
  tasks_in "$home" 'done' "$legacy_id" >/dev/null \
    || fail "could not complete the kindless legacy delivery"

  json=$(run_bearings "$home" --all-landed) \
    || fail "Bearings failed after retained delivery answers"
  printf '%s' "$json" | jq -e \
    --arg retained_id "$retained_id" --arg retained "data/$retained_id/report.md" \
    --arg precedence_id "$precedence_id" \
    --arg precedence "data/$precedence_id/report.md" \
    --arg rejected_id "$rejected_id" --arg rejected_local_id "$rejected_local_id" \
    --arg report_question_id "$report_question_id" \
    --arg approved_id "$approved_id" --arg local_id "$local_id" \
    --arg approved_pr "$approved_pr" --arg released_id "$released_id" \
    --arg answered_id "$answered_id" --arg reportless_scout_id "$reportless_scout_id" \
    --arg legacy_id "$legacy_id" --arg decision_local_id "$decision_local_id" \
    --arg released "data/$released_id/report.md" '
      (.landed | any(.id == $retained_id and .artifact == $retained))
        and (.landed | any(.id == $precedence_id and .artifact == $precedence))
        and (.landed | any(.id == $rejected_id) | not)
        and (.landed | any(.id == $rejected_local_id) | not)
        and (.landed | any(.id == $report_question_id) | not)
        and (.landed | any(.id == $approved_id and .artifact == $approved_pr))
        and (.landed | any(.id == $local_id))
        and (.landed | any(.id == $released_id and .artifact == $released))
        # Without the explicit captain-kind boundary, the artifactless answered
        # call falls through the compatibility path and this assertion fails.
        and (.landed | any(.id == $answered_id) | not)
        # Without the explicit scout-kind boundary, this row is rendered with
        # an empty artifact even though a scout has no delivery without a report.
        and (.landed | any(.id == $reportless_scout_id) | not)
        # Requiring a present non-captain kind would also remove this older
        # artifactless delivery, so the compatibility boundary stays observable.
        and (.landed | any(.id == $legacy_id))
        # The captain worded this decision "local main" and the work closed
        # with no artifact, so reading that prose as a recorded note would
        # publish a local-only landing that never happened.
        and (.landed | any(.id == $decision_local_id and .artifact == "-"))
    ' >/dev/null || fail "released, retained, or rejected deliveries were misclassified: $json"
  pass "release and scout report retention distinguish deliveries from rejected merge answers"
}

# Retention happens after destructive cleanup, through the same pending record
# an ordinary close stages first. A cleanup that fails part-way therefore leaves
# the row exactly as it was, and the next session start finishes the retention
# instead of closing the captain's question.
test_interrupted_cleanup_keeps_the_captain_call_recoverable() {
  local home id wt show rc bootstrap
  home=$(make_home teardown-held-interrupted)
  id=sample-held-cleanup-failure
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  git -C "$home/projects/sample" init -q || fail "could not initialize cleanup-failure project fixture"
  tasks_in "$home" add "$id" "Investigate failed sample cleanup" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the cleanup-failure fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Failed cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after cleanup retry" >/dev/null \
    || fail "could not hold the cleanup-failure fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the cleanup-failure fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.meta" "a failed cleanup removed the task record"
  assert_present "$home/state/$id.backlog-close" \
    "a failed cleanup lost the pending record that replays the retention"
  show=$(tasks_in "$home" show "$id" --full) || fail "a failed cleanup erased the captain call"
  assert_contains "$show" "state: in_flight" "a failed cleanup changed the row before cleanup succeeded"
  assert_contains "$show" "hold_kind: captain" "a failed cleanup dropped the captain hold"
  assert_not_contains "$show" "Deliverable of the finished work" \
    "the deliverable was recorded before destructive cleanup succeeded"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay the interrupted retention: $bootstrap"
  assert_contains "$bootstrap" "kept the captain call for $id open" \
    "session start did not report the retained captain call"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  show=$(tasks_in "$home" show "$id" --full) || fail "session start erased the captain call"
  assert_not_contains "$show" "state: done" "session start closed the captain call with no recorded answer"
  assert_contains "$show" "state: queued" "session start did not return the captain call to the queue"
  assert_contains "$show" "hold_kind: captain" "session start dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$id/report.md" \
    "session start did not record the finished work's deliverable"
  pass "an interrupted cleanup keeps the captain call recoverable and session start retains it"
}

test_answer_before_cleanup_replay_preserves_the_retained_report() {
  local home id wt rc bootstrap json
  home=$(make_home answer-before-cleanup-replay)
  id=sample-answer-before-cleanup-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample"
  tasks_in "$home" add "$id" "Investigate answer before cleanup replay" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the answer-before-replay fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Interrupted cleanup\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the answer-before-replay fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the answer-before-replay fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer before cleanup replay"
  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.meta" "session start left the interrupted task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the pending record behind"
  json=$(run_bearings "$home") || fail "Bearings failed after the answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e \
    --arg id "$id" --arg report "data/$id/report.md" \
    '.landed | any(.id == $id and .artifact == $report)' >/dev/null \
    || fail "the retained report disappeared when the captain answered before replay: $json"
  pass "an answer before cleanup replay preserves the retained report"
}

test_answer_before_cleanup_replay_notes_a_retained_gerrit_change() {
  local home id repo wt rc show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home answer-before-replay-gerrit)
  id=sample-answer-before-replay-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/answer-before-replay-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit answer fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted cleanup lost its retained-artifact record"

  printf 'Proceed with the landed change.\n' > "$home/answer.txt"
  run_captain "$home" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
    || fail "the captain could not answer a Gerrit task before cleanup replay"
  show=$(tasks_in "$home" show "$id" --full) || fail "the answered Gerrit row is gone"
  assert_contains "$show" "state: done" "the answer did not close the Gerrit row"
  assert_contains "$show" "Gerrit change $gerrit_url" \
    "the answer dropped the retained Gerrit change URL"
  pass "an answer before cleanup replay notes the retained Gerrit change"
}

test_unusable_pending_close_record_names_its_reason() {
  local home id wt rc err marker
  home=$(make_home unusable-pending-close-reason)
  id=sample-unusable-pending-close
  wt="$home/projects/$id"
  marker="$home/state/$id.backlog-close"
  mkdir -p "$home/data/$id" "$wt" "$home/projects/sample" "$home/elsewhere"
  tasks_in "$home" add "$id" "Investigate the unusable pending close" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the unusable pending-close fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Unusable pending close\n\nThe captain call remains open.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold "$id" --reason "captain must choose after interrupted cleanup" \
    >/dev/null || fail "could not hold the unusable pending-close fixture"
  complete_through_sibling "$home" "$id" >/dev/null \
    || fail "completion gate failed for the unusable pending-close fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup succeeded despite the failed worktree return"
  assert_present "$marker" "the interrupted cleanup lost its retained-artifact record"
  sed "s|^data=.*$|data=$home/elsewhere|" "$marker" > "$marker.rewritten" \
    || fail "could not rewrite the pending-close record"
  mv "$marker.rewritten" "$marker"

  printf 'Proceed with the reported result.\n' > "$home/answer.txt"
  set +e
  err=$(run_captain "$home" answer "$id" --decision-file "$home/answer.txt" 2>&1 >/dev/null)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the unusable pending-close record was answered as if it were valid"
  assert_contains "$err" "$marker" \
    "the refusal did not name the pending-close record the captain must repair"
  assert_contains "$err" "foreign data directory" \
    "the refusal did not name why the pending-close record could not be used"
  pass "an unusable pending-close record names its reason instead of a bare refusal"
}

test_relocated_report_does_not_wedge_an_answer_before_replay() {
  local home data id wt rc show bootstrap json
  home=$(make_home relocated-answer-before-replay)
  data="$home/données"
  mv "$home/data" "$data"
  id=sample-relocated-answer-before-replay
  wt="$home/projects/$id"
  mkdir -p "$home/data" "$data/$id" "$wt" "$home/projects/sample"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated answer replay" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated answer-before-replay fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$wt" "project=$home/projects/sample" \
    "harness=codex" "kind=scout" "mode=scout" "spawn_gen=fixture-$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated interrupted cleanup\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose after relocated interrupted cleanup" >/dev/null \
    || fail "could not hold the relocated answer-before-replay fixture"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated answer-before-replay fixture"
  cat > "$home/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$home/fakebin/treehouse"

  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "relocated cleanup succeeded despite the failed worktree return"
  assert_present "$home/state/$id.backlog-close" \
    "the interrupted relocated cleanup lost its pending record"

  printf 'Proceed despite the reporting limitation.\n' > "$home/answer.txt"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" \
    >/dev/null || fail "the unsupported relocated report wedged the captain's answer"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the answered relocated row disappeared"
  assert_contains "$show" "state: done" "the relocated report kept the answered call open"
  assert_contains "$show" "held: no" "the relocated report kept the answered call held"

  fm_fake_exit0 "$home/fakebin" treehouse
  bootstrap=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_BOOTSTRAP_NETWORK=skip \
    "$ROOT/bin/fm-bootstrap.sh" 2>&1) \
    || fail "session start could not replay relocated cleanup after the answer: $bootstrap"
  assert_absent "$home/state/$id.meta" "session start left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "session start left the relocated pending record behind"
  json=$(PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" \
    FM_BEARINGS_NOW=2026-07-14T12:00:00Z "$BEARINGS" --json) \
    || fail "Bearings failed after the relocated answer-before-replay lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" \
    '.landed | any(.id == $id) | not' >/dev/null \
    || fail "the unsupported relocated report was published as a landed delivery: $json"
  pass "an unsupported relocated report does not wedge the captain's answer"
}

# A home whose data directory is relocated keeps one backlog; the predicate and
# the retention must address it the way teardown does, not FM_HOME/data.
test_teardown_retains_captain_calls_in_a_relocated_backlog() {
  local home data id show
  home=$(make_home teardown-relocated-hold)
  data="$home/records"
  mv "$home/data" "$data"
  id=sample-relocated-hold
  mkdir -p "$home/data" "$data/$id"
  # A backlog at the default location stays empty, so a wrongly addressed read
  # would find no row at all.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  (cd "$home" && tasks-axi add "$id" "Investigate relocated sample hold" --kind scout \
    --repo sample --start --file "$data/backlog.md" >/dev/null) \
    || fail "could not create the relocated captain-hold fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Relocated hold\n\nThe captain call remains open.\n' > "$data/$id/report.md"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id" \
    --reason "captain must choose the relocated sample outcome" >/dev/null \
    || fail "could not hold the relocated work item"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" hold "$id-call" --title "Sibling captain call" \
    --reason "captain must decide the sibling call" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the sibling captain call"
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" complete "$id" "$id-call" >/dev/null \
    || fail "completion gate failed for the relocated captain hold"

  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of the relocated captain hold failed: $(cat "$home/teardown.err")"
  show=$(cd "$home" && tasks-axi show "$id" --full --file "$data/backlog.md") \
    || fail "the relocated captain-held row disappeared"
  assert_not_contains "$show" "state: done" "cleanup closed the relocated captain call"
  assert_contains "$show" "state: queued" "cleanup left the relocated captain call reading as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the relocated captain hold"
  assert_contains "$show" "Deliverable of the finished work: report records/$id/report.md" \
    "cleanup did not record the deliverable in the relocated backlog"
  assert_absent "$home/state/$id.meta" "cleanup left the relocated task record behind"
  assert_absent "$home/state/$id.backlog-close" "cleanup left its pending record behind"
  assert_no_grep "$id" "$home/data/backlog.md" "cleanup wrote to the empty default-location backlog"
  pass "cleanup retains captain calls in the configured backlog"
}

test_teardown_retains_a_gerrit_captain_call_with_its_change_url() {
  local home id repo wt show real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  home=$(make_home teardown-held-gerrit)
  id=sample-held-gerrit
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" fm/held-gerrit
  tasks_in "$home" add "$id" "Ship the held Gerrit change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held Gerrit fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$gerrit_url" "spawn_gen=fixture-$id"
  printf 'done: change landed\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must choose the follow-up" >/dev/null \
    || fail "could not hold the landed Gerrit task for the captain"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "cleanup of a captain-held Gerrit task failed: $(cat "$home/teardown.err")"
  show=$(tasks_in "$home" show "$id" --full) || fail "the captain-held Gerrit row is gone after cleanup"
  assert_contains "$show" "state: queued" "the held Gerrit row still reads as worked on"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: Gerrit change $gerrit_url" \
    "the Gerrit change URL was not recorded on the still-open row"
  assert_absent "$home/state/$id.backlog-close" \
    "successful cleanup left its pending transition record behind"
  pass "cleanup keeps a captain-held Gerrit task open and records its change URL"
}

test_merge_approval_releases_before_zero_done_retention() {
  local home id archive repo wt pr show
  home=$(make_home zero-done-retention)
  id=sample-zero-retention-merge
  archive="$home/data/done-archive.md"
  repo="$home/projects/sample"
  wt="$home/projects/$id"
  pr="https://github.com/sample/sample/pull/19"
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' \
    'path = "data/backlog.md"' 'archive = "data/done-archive.md"' \
    'done_keep = 0' > "$home/.tasks.toml"
  fm_git_worktree "$repo" "$wt" fm/zero-retention-merge
  tasks_in "$home" add "$id" "Ship zero-retention merge $pr" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the zero-retention fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the zero-retention merge"
  printf 'Merge the approved change.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved zero-retention merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge row disappeared"
  assert_contains "$show" "state: in_flight" \
    "merge approval completed the zero-retention row before landing"
  assert_contains "$show" "Resolution mode: released" \
    "merge approval did not record the existing release mode"
  run_teardown "$home" "$id" > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "zero-retention cleanup failed: $(cat "$home/teardown.err")"
  assert_no_grep "$id" "$home/data/backlog.md" \
    "zero-retention cleanup kept the completed row in the active backlog"
  assert_grep "$id" "$archive" "zero-retention cleanup did not archive the completed row"
  assert_grep "$pr" "$archive" "zero-retention archival lost the merged pull request"
  assert_grep "Merge the approved change." "$archive" \
    "zero-retention archival lost the recorded merge approval"
  assert_absent "$home/state/$id.meta" "zero-retention cleanup retained task metadata"
  assert_absent "$home/state/$id.backlog-close" \
    "zero-retention cleanup retained its pending close record"
  pass "merge approval releases before zero-retention cleanup records completion"
}

test_pr_merge_entrypoint_refuses_a_captain_held_task() {
  local home pr_id pr repo wt rc
  home=$(make_home held-merge-entrypoints)
  configure_merged_github "$home"

  pr_id=sample-held-pr-entrypoint
  pr=https://github.com/sample/sample/pull/31
  repo="$home/projects/sample-pr"
  wt="$home/projects/$pr_id"
  fm_git_worktree "$repo" "$wt" "fm/$pr_id"
  tasks_in "$home" add "$pr_id" "Ship the held pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held PR fixture"
  fm_write_meta "$home/state/$pr_id.meta" \
    "window=firstmate:fm-$pr_id" "endpoint_task_id=$pr_id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$pr_id"
  run_captain "$home" hold "$pr_id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR entrypoint fixture"

  # Without the entrypoint guard, this run reaches gh and returns success even
  # though the task is still held for the captain.
  set +e
  run_pr_merge "$home" "$pr_id" "$pr" > "$home/pr.out" 2> "$home/pr.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted a still-held task"
  assert_no_grep 'pr merge 31 ' "$home/gh.log" \
    "the PR merge entrypoint reached the irreversible forge call for a held task"
  assert_grep "$pr_id is still held for the captain" "$home/pr.err" \
    "the PR merge refusal did not name the held task"
  assert_absent "$home/state/.control-$pr_id.lock" \
    "the refused PR merge left its task control lock held"
  pass "the PR merge entrypoint refuses a captain-held task before merging"
}

test_local_merge_entrypoint_refuses_a_captain_held_task() {
  local home local_id local_repo local_wt before after rc
  home=$(make_home held-local-merge-entrypoint)
  local_id=sample-held-local-entrypoint
  local_repo="$home/projects/sample-local"
  local_wt="$home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'held local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'held local delivery'
  tasks_in "$home" add "$local_id" "Ship the held local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the held local fixture"
  fm_write_meta "$home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_wt" rev-parse HEAD)" >> "$home/state/$local_id.meta"
  run_captain "$home" hold "$local_id" --reason "captain local merge approval pending" \
    >/dev/null || fail "could not hold the local entrypoint fixture"
  before=$(git -C "$local_repo" rev-parse main)

  # Without the entrypoint guard, this run fast-forwards main while the task
  # still carries the captain hold.
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$home/local.out" 2> "$home/local.err"
  rc=$?
  set -e
  after=$(git -C "$local_repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted a still-held task"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main for a held task"
  assert_grep "$local_id is still held for the captain" "$home/local.err" \
    "the local merge refusal did not name the held task"
  assert_absent "$home/state/.control-$local_id.lock" \
    "the refused local merge left its task control lock held"
  pass "the local merge entrypoint refuses a captain-held task before merging"
}

test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id pr rc merge_count
  home=$(make_home missing-pr-authority-record)
  configure_merged_github "$home"
  id=sample-missing-pr-authority
  pr=https://github.com/sample/sample/pull/43
  write_origin_meta "$home" "$id" ship

  # A backlog that exists but cannot be read may hide a live captain hold, so
  # the merge must refuse without reaching the forge.
  chmod 000 "$home/data/backlog.md"
  set +e
  run_pr_merge "$home" "$id" "$pr" > "$home/missing-pr.out" 2> "$home/missing-pr.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  [ "$rc" -ne 0 ] || fail "the PR merge entrypoint accepted an unreadable captain-hold authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-pr.err" \
    "the PR merge refusal did not name its unreadable authority record"
  assert_no_grep 'pr merge 43 ' "$home/gh.log" \
    "the PR merge entrypoint reached the forge without a readable authority record"

  # A home with no backlog at all records no captain calls, so nothing can be
  # held and the merge proceeds.
  rm "$home/data/backlog.md"
  run_pr_merge "$home" "$id" "$pr" > "$home/absent-pr.out" 2> "$home/absent-pr.err" \
    || fail "the PR merge entrypoint refused a home carrying no backlog"
  merge_count=$(grep -c 'pr merge 43 ' "$home/gh.log" || true)
  [ "$merge_count" -eq 1 ] || fail "the absent backlog did not permit exactly one PR merge"
  pass "the PR merge entrypoint separates an unreadable authority record from an absent one"
}

test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one() {
  local home id repo wt before after rc
  home=$(make_home missing-local-authority-record)
  id=sample-missing-local-authority
  repo="$home/projects/sample-local"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  printf 'untracked local delivery\n' > "$wt/local.txt"
  git -C "$wt" add local.txt
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'untracked local delivery'
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$id"
  printf 'local_done_head=%s\n' "$(git -C "$wt" rev-parse HEAD)" >> "$home/state/$id.meta"
  before=$(git -C "$repo" rev-parse main)

  # Unreadable authority record: refuse, and leave the default branch where it was.
  chmod 000 "$home/data/backlog.md"
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/missing-local.out" 2> "$home/missing-local.err"
  rc=$?
  set -e
  chmod 644 "$home/data/backlog.md"
  after=$(git -C "$repo" rev-parse main)
  [ "$rc" -ne 0 ] || fail "the local merge entrypoint accepted an unreadable captain-hold authority record"
  [ "$after" = "$before" ] || fail "the local merge entrypoint moved main without a readable authority record"
  assert_grep "could not determine whether task $id is still held for the captain" "$home/missing-local.err" \
    "the local merge refusal did not name its unreadable authority record"

  # No backlog at all: nothing can be held, so the landing proceeds.
  rm "$home/data/backlog.md"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-merge-local.sh" "$id" \
    > "$home/absent-local.out" 2> "$home/absent-local.err" \
    || fail "the local merge entrypoint refused a home carrying no backlog"
  after=$(git -C "$repo" rev-parse main)
  [ "$after" != "$before" ] || fail "the absent backlog did not permit the local merge"
  pass "the local merge entrypoint separates an unreadable authority record from an absent one"
}

test_merge_entrypoints_validate_identity_and_state_before_locking() {
  local home pr_state local_state bad_id rc
  home=$(make_home invalid-merge-entrypoint-inputs)
  configure_merged_github "$home"

  pr_state="$home/missing-pr-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$pr_state" \
    "$ROOT/bin/fm-pr-merge.sh" sample-missing-pr-state \
    https://github.com/sample/sample/pull/41 \
    > "$home/missing-pr-state.out" 2> "$home/missing-pr-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the PR merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the PR merge accepted a missing state directory"
  assert_absent "$pr_state" "the PR merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-pr-state.err" \
    "the PR merge did not identify its missing state directory"

  local_state="$home/missing-local-state"
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$local_state" \
    "$ROOT/bin/fm-merge-local.sh" sample-missing-local-state \
    > "$home/missing-local-state.out" 2> "$home/missing-local-state.err"
  rc=$?
  set -e
  # Without pre-lock state validation, the lock library creates the missing
  # directory before the entrypoint discovers that no task record exists.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever for a missing state directory"
  [ "$rc" -ne 0 ] || fail "the local merge accepted a missing state directory"
  assert_absent "$local_state" "the local merge created a missing state directory while refusing"
  assert_grep "state directory is not a real directory" "$home/missing-local-state.err" \
    "the local merge did not identify its missing state directory"

  bad_id=sample/bad-local-id
  set +e
  fm_run_timed 2 env PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-merge-local.sh" "$bad_id" \
    > "$home/bad-local-id.out" 2> "$home/bad-local-id.err"
  rc=$?
  set -e
  # Without canonical ID validation, the slash creates a nested lock path whose
  # absent parent makes the blocking acquisition retry until the bound expires.
  [ "$rc" -ne 124 ] || fail "the local merge waited forever on a slash-containing task id"
  [ "$rc" -eq 2 ] || fail "the local merge returned $rc instead of rejecting the unsafe task id"
  assert_grep "invalid local merge request" "$home/bad-local-id.err" \
    "the local merge did not identify the unsafe task id"
  assert_absent "$home/state/.control-sample" \
    "the unsafe task id constructed a nested task control path"
  pass "merge entrypoints reject unsafe identities and absent state before locking"
}

test_merge_entrypoints_refuse_a_reused_task_incarnation() {
  local home id pr old_repo old_wt new_repo new_wt teardown_pid merge_pid
  local teardown_ready teardown_release merge_ready merge_release teardown_rc merge_rc
  local local_home local_id local_old_repo local_old_wt local_new_repo local_new_wt
  local local_teardown_pid local_merge_pid local_teardown_ready local_teardown_release
  local local_merge_ready local_merge_release local_teardown_rc local_merge_rc before after
  local real_perl real_sleep
  real_perl=$(command -v perl)
  real_sleep=$(command -v sleep)

  home=$(make_home reused-pr-incarnation)
  configure_merged_github "$home"
  install_reused_task_barriers "$home"
  id=sample-reused-pr-incarnation
  pr=https://github.com/sample/sample/pull/42
  old_repo="$home/projects/sample-reused-pr-old"
  old_wt="$home/projects/$id"
  fm_git_worktree "$old_repo" "$old_wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the original pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$old_wt" \
    "project=$old_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=original-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"

  teardown_ready="$home/reuse-teardown-ready"
  teardown_release="$home/reuse-teardown-release"
  merge_ready="$home/reuse-merge-ready"
  merge_release="$home/reuse-merge-release"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$id" --force > "$home/reuse-teardown.out" \
    2> "$home/reuse-teardown.err" &
  teardown_pid=$!
  if ! wait_for_test_file "$teardown_ready" "$teardown_pid"; then
    : > "$teardown_release"
    wait "$teardown_pid" 2>/dev/null || true
    fail "forced PR cleanup did not reach its task-locked synchronization point"
  fi

  FM_TEST_REUSE_MERGE=1 FM_TEST_REUSE_MERGE_ONCE="$home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$merge_ready" FM_TEST_REUSE_MERGE_RELEASE="$merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    run_pr_merge "$home" "$id" "$pr" > "$home/reuse-merge.out" \
    2> "$home/reuse-merge.err" &
  merge_pid=$!
  if ! wait_for_test_file "$merge_ready" "$merge_pid"; then
    : > "$teardown_release"
    : > "$merge_release"
    wait "$teardown_pid" 2>/dev/null || true
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not wait behind forced cleanup"
  fi

  : > "$teardown_release"
  set +e
  wait "$teardown_pid"
  teardown_rc=$?
  set -e
  if [ "$teardown_rc" -ne 0 ]; then
    : > "$merge_release"
    wait "$merge_pid" 2>/dev/null || true
    fail "forced PR cleanup failed before the task could be reused: $(cat "$home/reuse-teardown.err")"
  fi

  new_repo="$home/projects/sample-reused-pr-new"
  new_wt="$home/projects/reused-$id"
  fm_git_worktree "$new_repo" "$new_wt" "fm/$id"
  tasks_in "$home" reopen "$id" >/dev/null || fail "could not reopen the reused PR task"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$new_wt" \
    "project=$new_repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=replacement-$id"
  tasks_in "$home" start "$id" >/dev/null || fail "could not start the reused PR task"
  : > "$merge_release"
  set +e
  wait "$merge_pid"
  merge_rc=$?
  set -e

  # Without the pre-wait generation capture and locked comparison, the waiter
  # records and merges pull request 42 against the replacement task record.
  [ "$merge_rc" -ne 0 ] || fail "the PR merge accepted a replacement task incarnation"
  assert_no_grep 'pr merge 42 ' "$home/gh.log" \
    "the PR merge reached the forge for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$home/reuse-merge.err" \
    "the PR merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$id" "$home/state/$id.meta" \
    "the refused PR merge damaged the replacement task record"
  assert_absent "$home/state/.control-$id.lock" \
    "the reused-incarnation PR refusal left its task control lock held"

  local_home=$(make_home reused-local-incarnation)
  install_reused_task_barriers "$local_home"
  local_id=sample-reused-local-incarnation
  local_old_repo="$local_home/projects/sample-reused-local-old"
  local_old_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_old_repo" "$local_old_wt" "fm/$local_id"
  printf 'original local delivery\n' > "$local_old_wt/original.txt"
  git -C "$local_old_wt" add original.txt
  git -C "$local_old_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'original local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the original local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the original local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_old_wt" "project=$local_old_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=original-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_old_wt" rev-parse HEAD)" >> "$local_home/state/$local_id.meta"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"

  local_teardown_ready="$local_home/reuse-teardown-ready"
  local_teardown_release="$local_home/reuse-teardown-release"
  local_merge_ready="$local_home/reuse-merge-ready"
  local_merge_release="$local_home/reuse-merge-release"
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" FM_TEST_REUSE_TEARDOWN=1 \
    FM_TEST_REUSE_TEARDOWN_ONCE="$local_home/reuse-teardown-once" \
    FM_TEST_REUSE_TEARDOWN_READY="$local_teardown_ready" \
    FM_TEST_REUSE_TEARDOWN_RELEASE="$local_teardown_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    "$TEARDOWN" "$local_id" --force > "$local_home/reuse-teardown.out" \
    2> "$local_home/reuse-teardown.err" &
  local_teardown_pid=$!
  if ! wait_for_test_file "$local_teardown_ready" "$local_teardown_pid"; then
    : > "$local_teardown_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    fail "forced local cleanup did not reach its task-locked synchronization point"
  fi

  PATH="$local_home/fakebin:$PATH" FM_TEST_REUSE_MERGE=1 \
    FM_TEST_REUSE_MERGE_ONCE="$local_home/reuse-merge-once" \
    FM_TEST_REUSE_MERGE_READY="$local_merge_ready" \
    FM_TEST_REUSE_MERGE_RELEASE="$local_merge_release" \
    FM_TEST_REAL_PERL="$real_perl" FM_TEST_REAL_SLEEP="$real_sleep" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" > "$local_home/reuse-merge.out" \
    2> "$local_home/reuse-merge.err" &
  local_merge_pid=$!
  if ! wait_for_test_file "$local_merge_ready" "$local_merge_pid"; then
    : > "$local_teardown_release"
    : > "$local_merge_release"
    wait "$local_teardown_pid" 2>/dev/null || true
    wait "$local_merge_pid" 2>/dev/null || true
    fail "the local merge did not wait behind forced cleanup"
  fi

  : > "$local_teardown_release"
  set +e
  wait "$local_teardown_pid"
  local_teardown_rc=$?
  set -e
  if [ "$local_teardown_rc" -ne 0 ]; then
    : > "$local_merge_release"
    wait "$local_merge_pid" 2>/dev/null || true
    fail "forced local cleanup failed before the task could be reused: $(cat "$local_home/reuse-teardown.err")"
  fi

  local_new_repo="$local_home/projects/sample-reused-local-new"
  local_new_wt="$local_home/projects/reused-$local_id"
  fm_git_worktree "$local_new_repo" "$local_new_wt" "fm/$local_id"
  printf 'replacement local delivery\n' > "$local_new_wt/replacement.txt"
  git -C "$local_new_wt" add replacement.txt
  git -C "$local_new_wt" -c user.name='Firstmate Tests' \
    -c user.email='tests@example.invalid' commit -qm 'replacement local delivery'
  before=$(git -C "$local_new_repo" rev-parse main)
  tasks_in "$local_home" reopen "$local_id" >/dev/null \
    || fail "could not reopen the reused local task"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" \
    "worktree=$local_new_wt" "project=$local_new_repo" "harness=codex" \
    "kind=ship" "mode=local-only" "spawn_gen=replacement-$local_id"
  tasks_in "$local_home" start "$local_id" >/dev/null \
    || fail "could not start the reused local task"
  : > "$local_merge_release"
  set +e
  wait "$local_merge_pid"
  local_merge_rc=$?
  set -e
  after=$(git -C "$local_new_repo" rev-parse main)

  # Without the pre-wait generation capture and locked comparison, the waiter
  # fast-forwards the replacement task's branch despite never approving it.
  [ "$local_merge_rc" -ne 0 ] || fail "the local merge accepted a replacement task incarnation"
  [ "$after" = "$before" ] || fail "the local merge moved main for a replacement task incarnation"
  assert_grep "changed incarnation while waiting to merge" "$local_home/reuse-merge.err" \
    "the local merge did not identify the replacement task incarnation"
  assert_grep "spawn_gen=replacement-$local_id" "$local_home/state/$local_id.meta" \
    "the refused local merge damaged the replacement task record"
  assert_absent "$local_home/state/.control-$local_id.lock" \
    "the reused-incarnation local refusal left its task control lock held"
  pass "merge entrypoints refuse a replacement incarnation after waiting for cleanup"
}

test_merge_entrypoints_serialize_forced_teardown_before_task_reads() {
  local home id pr repo wt ready release merge_pid teardown_rc merge_rc real_grep
  local local_home local_id local_repo local_wt local_ready local_release local_pid
  local local_teardown_rc local_merge_rc real_git before after i

  home=$(make_home teardown-race-pr-entrypoint)
  configure_merged_github "$home"
  id=sample-teardown-race-pr
  pr=https://github.com/sample/sample/pull/33
  repo="$home/projects/sample-pr-race"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the released pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the PR teardown-race fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the PR teardown-race fixture"
  printf 'Merge the released pull request.\n' > "$home/race-answer.txt"
  run_captain "$home" answer "$id" --release --decision-file "$home/race-answer.txt" \
    >/dev/null || fail "could not release the PR teardown-race fixture"

  real_grep=$(command -v grep)
  ready="$home/pr-metadata-read-ready"
  release="$home/pr-metadata-read-release"
  cat > "$home/fakebin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -qxF ] && [ "${2:-}" = "pr=${FM_TEST_RACE_PR_URL:-}" ] \
    && [ "${3:-}" = "${FM_TEST_RACE_PR_META:-}" ]; then
  "$FM_TEST_REAL_GREP" "$@" || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  exit 0
fi
exec "$FM_TEST_REAL_GREP" "$@"
SH
  chmod +x "$home/fakebin/grep"
  FM_TEST_REAL_GREP="$real_grep" FM_TEST_RACE_PR_URL="$pr" \
    FM_TEST_RACE_PR_META="$home/state/$id.meta" FM_TEST_RACE_READY="$ready" \
    FM_TEST_RACE_RELEASE="$release" run_pr_merge "$home" "$id" "$pr" \
    > "$home/race-pr.out" 2> "$home/race-pr.err" &
  merge_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$ready" ] && break
    kill -0 "$merge_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$merge_pid" 2>/dev/null || true
    fail "the PR merge did not reach the post-metadata synchronization point"
  fi
  set +e
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/race-pr-teardown.out" 2> "$home/race-pr-teardown.err"
  teardown_rc=$?
  set -e
  : > "$release"
  wait "$merge_pid"
  merge_rc=$?

  # Without early lock ownership, forced cleanup succeeds after metadata is
  # recorded, and the resumed forge call merges work whose task was retired.
  [ "$teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between PR metadata recording and merge"
  assert_grep "another lifecycle action is already running for task $id" \
    "$home/race-pr-teardown.err" \
    "PR cleanup was not refused by the merge's task control lock"
  [ "$merge_rc" -eq 0 ] || fail "the serialized PR merge failed after cleanup was refused"
  assert_present "$home/state/$id.meta" "the refused PR cleanup removed task metadata"
  assert_grep 'pr merge 33 ' "$home/gh.log" \
    "the serialized PR merge did not reach the forge after cleanup was refused"

  local_home=$(make_home teardown-race-local-entrypoint)
  local_id=sample-teardown-race-local
  local_repo="$local_home/projects/sample-local-race"
  local_wt="$local_home/projects/$local_id"
  fm_git_worktree "$local_repo" "$local_wt" "fm/$local_id"
  printf 'serialized local delivery\n' > "$local_wt/local.txt"
  git -C "$local_wt" add local.txt
  git -C "$local_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'serialized local delivery'
  tasks_in "$local_home" add "$local_id" "Ship the released local change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the local teardown-race fixture"
  fm_write_meta "$local_home/state/$local_id.meta" \
    "window=firstmate:fm-$local_id" "endpoint_task_id=$local_id" "worktree=$local_wt" \
    "project=$local_repo" "harness=codex" "kind=ship" "mode=local-only" \
    "spawn_gen=fixture-$local_id"
  printf 'local_done_head=%s\n' "$(git -C "$local_wt" rev-parse HEAD)" >> "$local_home/state/$local_id.meta"
  printf 'done: local merge ready\n' > "$local_home/state/$local_id.status"
  run_captain "$local_home" hold "$local_id" \
    --reason "captain local merge approval pending" >/dev/null \
    || fail "could not hold the local teardown-race fixture"
  printf 'Land the released local change.\n' > "$local_home/race-answer.txt"
  run_captain "$local_home" answer "$local_id" --release \
    --decision-file "$local_home/race-answer.txt" >/dev/null \
    || fail "could not release the local teardown-race fixture"

  real_git=$(command -v git)
  local_ready="$local_home/local-validation-ready"
  local_release="$local_home/local-validation-release"
  cat > "$local_home/fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -C ] && [ "${2:-}" = "${FM_TEST_RACE_REPO:-}" ] \
    && [ "${3:-}" = merge-base ] && [ "${4:-}" = --is-ancestor ]; then
  output=$("$FM_TEST_REAL_GIT" "$@") || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do sleep 0.01; done
  printf '%s\n' "$output"
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$local_home/fakebin/git"
  before=$(git -C "$local_repo" rev-parse main)
  PATH="$local_home/fakebin:$PATH" FM_TEST_REAL_GIT="$real_git" \
    FM_TEST_RACE_REPO="$local_repo" FM_TEST_RACE_READY="$local_ready" \
    FM_TEST_RACE_RELEASE="$local_release" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$local_home" FM_STATE_OVERRIDE="$local_home/state" \
    FM_DATA_OVERRIDE="$local_home/data" FM_CONFIG_OVERRIDE="$local_home/config" \
    "$ROOT/bin/fm-merge-local.sh" "$local_id" \
    > "$local_home/race-local.out" 2> "$local_home/race-local.err" &
  local_pid=$!
  i=0
  while [ "$i" -lt 500 ]; do
    [ -e "$local_ready" ] && break
    kill -0 "$local_pid" 2>/dev/null || break
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$local_ready" ]; then
    : > "$local_release"
    wait "$local_pid" 2>/dev/null || true
    fail "the local merge did not reach the post-validation synchronization point"
  fi
  set +e
  PATH="$local_home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$local_home" \
    FM_STATE_OVERRIDE="$local_home/state" FM_DATA_OVERRIDE="$local_home/data" \
    FM_CONFIG_OVERRIDE="$local_home/config" "$TEARDOWN" "$local_id" --force \
    > "$local_home/race-local-teardown.out" 2> "$local_home/race-local-teardown.err"
  local_teardown_rc=$?
  set -e
  : > "$local_release"
  wait "$local_pid"
  local_merge_rc=$?
  after=$(git -C "$local_repo" rev-parse main)

  # Without early lock ownership, forced cleanup succeeds after validation and
  # the resumed fast-forward lands work whose task was already retired.
  [ "$local_teardown_rc" -ne 0 ] \
    || fail "forced cleanup retired the task between local validation and merge"
  assert_grep "another lifecycle action is already running for task $local_id" \
    "$local_home/race-local-teardown.err" \
    "local cleanup was not refused by the merge's task control lock"
  [ "$local_merge_rc" -eq 0 ] || fail "the serialized local merge failed after cleanup was refused"
  [ "$after" != "$before" ] || fail "the serialized local merge did not fast-forward main"
  assert_present "$local_home/state/$local_id.meta" \
    "the refused local cleanup removed task metadata"
  pass "merge entrypoints own task state before forced cleanup can retire it"
}

# No regression covers a re-hold after a merge lands and before cleanup because
# that accepted window spans two separate lifecycle owners.
# Queued forge merges are also uncovered because they land asynchronously after
# the local merge command and its task control lock have returned.
test_released_merge_passes_the_entrypoint_and_lands() {
  local home id pr repo wt show json
  home=$(make_home released-merge-entrypoint)
  configure_merged_github "$home"
  id=sample-released-merge
  pr=https://github.com/sample/sample/pull/32
  repo="$home/projects/sample-released"
  wt="$home/projects/$id"
  fm_git_worktree "$repo" "$wt" "fm/$id"
  tasks_in "$home" add "$id" "Ship the approved pull request" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the released merge fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$wt" \
    "project=$repo" "harness=codex" "kind=ship" "mode=no-mistakes" \
    "pr=$pr" "spawn_gen=fixture-$id"
  printf 'done: merge ready\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain merge approval pending" >/dev/null \
    || fail "could not hold the released merge fixture"
  printf 'Merge the approved pull request.\n' > "$home/merge-answer.txt"
  run_captain "$home" answer "$id" --release \
    --decision-file "$home/merge-answer.txt" >/dev/null \
    || fail "could not release the approved merge"
  show=$(tasks_in "$home" show "$id" --full) || fail "the released merge task disappeared"
  assert_not_contains "$show" "hold_kind: captain" \
    "the approved merge remained captain-held after its release"
  run_pr_merge "$home" "$id" "$pr" > "$home/merge.out" 2> "$home/merge.err" \
    || fail "the released merge was refused: $(cat "$home/merge.err")"
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err" \
    || fail "the released merge cleanup failed: $(cat "$home/teardown.err")"
  json=$(run_bearings "$home") || fail "Bearings failed after the released merge lifecycle"
  printf '%s' "$json" | jq -e --arg id "$id" --arg pr "$pr" \
    '.landed | any(.id == $id and .artifact == $pr)' >/dev/null \
    || fail "the released merge was absent from Recently Landed: $json"
  pass "a released merge passes the guarded entrypoint and remains recently landed"
}

# "Cannot tell" is not permission to close. A ship row has no separate
# inventory gate ahead of the close, so the predicate itself must refuse before
# any destructive step when the hold cannot be read.
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read() {
  local home id rc show
  home=$(make_home teardown-ship-hold-read-error)
  id=sample-unreadable-ship-hold
  tasks_in "$home" add "$id" "Ship the sample change" --kind ship \
    --repo sample --start >/dev/null || fail "could not create the unreadable-hold fixture"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/missing-$id" \
    "project=$home/projects/sample" "harness=codex" "kind=ship" "mode=direct-PR" \
    "spawn_gen=fixture-$id"
  printf 'done: PR https://github.com/sample/sample/pull/7\n' > "$home/state/$id.status"
  run_captain "$home" hold "$id" --reason "captain must approve the sample change" >/dev/null \
    || fail "could not hold the ship fixture for the captain"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = "${TASKS_AXI_FAIL_SHOW_ID:-}" ]; then
  printf 'error: temporary backlog read failure\n' >&2
  exit 75
fi
exec "${REAL_TASKS_AXI:?}" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"

  set +e
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    TASKS_AXI_FAIL_SHOW_ID="$id" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$TEARDOWN" "$id" --force \
    > "$home/teardown.out" 2> "$home/teardown.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup treated an unreadable captain hold as permission to close"
  assert_present "$home/state/$id.meta" "read uncertainty must refuse before removing the task record"
  assert_absent "$home/state/$id.backlog-close" "read uncertainty staged a pending transition anyway"
  show=$(tasks_in "$home" show "$id" --full) || fail "the unreadable captain-held row disappeared"
  assert_contains "$show" "state: in_flight" "read uncertainty allowed cleanup to move the row"
  assert_contains "$show" "hold_kind: captain" "read uncertainty dropped the captain hold"
  assert_grep "could not be read" "$home/teardown.err" "cleanup did not explain the refusal"
  assert_grep "temporary backlog read failure" "$home/teardown.err" \
    "the underlying captain-hold read failure was hidden"
  pass "cleanup refuses a ship row when its captain hold cannot be read"
}

# A shown scalar field is a JSON-encoded bare string, and JSON::PP accepts one
# only when allow_nonref is on. Recent releases default it on, so this case
# forces the older default back off for every perl the command spawns - the same
# rejection a host with JSON::PP 2.27202 produces - then drives both paths that
# read a body back: holding a task for the captain, and the cleanup that retains
# a captain-held row with its deliverable.
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default() {
  local home shim id show probe scout
  home=$(make_home nonref-default)
  shim="$home/no-nonref-default"
  mkdir -p "$shim"
  cat > "$shim/FmNoNonrefDefault.pm" <<'PM'
package FmNoNonrefDefault;
require JSON::PP;
my $new = \&JSON::PP::new;
{
  no warnings 'redefine';
  *JSON::PP::new = sub { my $self = $new->(@_); $self->allow_nonref(0); $self };
}
1;
PM

  # Without this the case would pass on any decode path at all, including the
  # one this regression exists to catch.
  probe=$(printf '%s' '"probe"' | PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    perl -MJSON::PP -e 'local $/; eval { decode_json(<STDIN>) };
      print $@ ? "rejects" : "accepts";')
  [ "$probe" = rejects ] \
    || fail "the simulated older default still accepted a bare scalar"

  id=sample-nonref-body
  tasks_in "$home" add "$id" "Work carrying a body" --kind ship --repo sample \
    --body 'First line of the plan.' >/dev/null \
    || fail "could not create the task carrying a body"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_captain "$home" hold "$id" --reason "captain go needed" >/dev/null \
    || fail "a captain hold failed where allow_nonref is not on by default"
  show=$(tasks_in "$home" show "$id" --full) || fail "the held row disappeared"
  assert_contains "$show" "hold_kind: captain" "the hold lost its captain kind"
  assert_contains "$show" "Captain hold set:" "the hold lost its hold-set stamp"
  assert_contains "$show" "First line of the plan." "the hold lost the original body"

  # Cleanup reads the same body back to append the finished work's deliverable.
  scout=sample-nonref-scout
  mkdir -p "$home/data/$scout"
  tasks_in "$home" add "$scout" "Investigate the sample body decode" --kind scout \
    --repo sample --start >/dev/null || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$scout"
  printf 'done: report complete\n' > "$home/state/$scout.status"
  printf '# Sample body decode\n\nOne captain choice remains.\n' \
    > "$home/data/$scout/report.md"
  run_captain "$home" hold "$scout" --reason "captain must choose" >/dev/null \
    || fail "could not hold the investigation for the captain"
  complete_through_sibling "$home" "$scout" >/dev/null \
    || fail "the completion gate failed with the origin as its own captain call"
  PERL5LIB="$shim" PERL5OPT=-MFmNoNonrefDefault \
    run_teardown "$home" "$scout" > "$home/nonref.out" 2> "$home/nonref.err" \
    || fail "cleanup of a captain-held row failed where allow_nonref is not on by default: $(cat "$home/nonref.err")"
  show=$(tasks_in "$home" show "$scout" --full) || fail "the retained row disappeared"
  assert_contains "$show" "hold_kind: captain" "cleanup dropped the captain hold"
  assert_contains "$show" "Deliverable of the finished work: report data/$scout/report.md" \
    "cleanup lost the deliverable it could not decode a body to append to"
  assert_contains "$show" "Captain hold set:" "cleanup lost the hold-set stamp"
  pass "both body-decoding paths work without the allow_nonref default"
}

test_retained_body_keeps_its_utf8_bytes() {
  local home accented wide narrow_id wide_id stored
  home=$(make_home retain-utf8)
  # Built from escapes so this file stays ASCII and the intended bytes are
  # explicit: U+00E9 is the latin-1-representable case, U+2014 the wider one.
  accented=$(printf 'caf\xc3\xa9')
  wide=$(printf '\xe2\x80\x94')
  stored="$home/data/backlog.md"

  # A body whose characters are all at or below U+00FF.
  narrow_id=sample-utf8-narrow
  retain_row_with_body "$home" "$narrow_id" "Serve the $accented black, no sugar."
  # data/backlog.md is the markdown backend's own persisted artifact, read here
  # for its bytes because the shown field re-encodes them.
  assert_grep "Deliverable of the finished work: report data/$narrow_id/report.md" "$stored" \
    "cleanup did not rewrite the retained body, so nothing decoded it"
  LC_ALL=C grep -qF "$accented" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character at or below U+00FF"
  ! LC_ALL=C grep -q "$(printf '[\xe9]')" "$stored" \
    || fail "the retained body holds a lone latin-1 byte, so it is no longer valid UTF-8"

  # A body carrying a character above U+00FF keeps its bytes and stays quiet.
  wide_id=sample-utf8-wide
  retain_row_with_body "$home" "$wide_id" "Serve it $wide black, no sugar."
  LC_ALL=C grep -qF "$wide" "$stored" \
    || fail "the retained body lost the UTF-8 bytes of a character above U+00FF"
  assert_no_grep "Wide character" "$home/$wide_id.err" \
    "cleanup warned about a wide character instead of writing raw bytes"

  pass "cleanup preserves every byte of a retained body's non-ASCII characters"
}

# A refused hold must never read as a recorded one. The gate used to accept the
# origin as its own inventory whenever the origin row looked durable, so a hold
# that failed just before `complete <origin> <origin>` left a satisfied gate
# with no captain call recorded.
test_origin_is_never_its_own_inventory_entry() {
  local home id
  home=$(make_home origin-self-inventory)
  id=sample-self-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate sample self review" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the investigation fixture"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  if run_captain "$home" hold "$id" --reason "" >/dev/null 2> "$home/hold.err"; then
    fail "hold accepted an empty reason"
  fi
  if run_captain "$home" complete "$id" "$id" > "$home/self.out" 2> "$home/self.err"; then
    fail "complete accepted the origin as its own inventory after a failed hold"
  fi
  assert_grep "cannot be its own captain-call inventory entry" "$home/self.err" \
    "the refusal does not say why the origin was rejected"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  # Holding the origin row itself must not let it vouch for itself either.
  run_captain "$home" hold "$id" --reason "captain must choose" >/dev/null \
    || fail "could not hold the origin row"
  if run_captain "$home" complete "$id" "$id" > "$home/held.out" 2> "$home/held.err"; then
    fail "complete accepted a held origin row as its own inventory"
  fi
  pass "complete refuses the origin as its own captain-call inventory"
}

# `hold --origin` records which origin a call was held for, and `complete`
# refuses a task held for a different origin. A hold recorded before that
# record existed, or without --origin, still verifies and is flagged.
test_complete_refuses_an_entry_held_for_another_origin() {
  local home id other o out
  home=$(make_home origin-mismatch)
  id=sample-first-review
  other=sample-second-review
  for o in "$id" "$other"; do
    mkdir -p "$home/data/$o"
    tasks_in "$home" add "$o" "Investigate $o" --kind scout --repo sample --start >/dev/null \
      || fail "could not create the $o fixture"
    write_origin_meta "$home" "$o"
    printf 'done: report complete\n' > "$home/state/$o.status"
  done
  run_captain "$home" hold sample-other-call --title "Call for the second review" \
    --reason "captain must decide" --repo sample --origin "$other" >/dev/null \
    || fail "could not hold the call recorded for the second review"
  if run_captain "$home" complete "$id" sample-other-call > "$home/mismatch.out" 2> "$home/mismatch.err"; then
    fail "complete accepted an entry held for a different origin"
  fi
  assert_grep "was held for origin $other, not $id" "$home/mismatch.err" \
    "the refusal does not name both origins"
  assert_no_grep "decisions_reviewed=1" "$home/state/$id.meta" \
    "the refused completion recorded an inventory attestation"

  run_captain "$home" hold sample-own-call --title "Call for the first review" \
    --reason "captain must decide" --repo sample --origin "$id" >/dev/null \
    || fail "could not hold the call recorded for the first review"
  out=$(run_captain "$home" complete "$id" sample-own-call) \
    || fail "complete refused an entry held for its own origin"
  assert_not_contains "$out" "no recorded origin" \
    "an entry with a recorded origin was flagged as unrecorded"

  tasks_in "$home" add sample-old-call "Call held before origins were recorded" --kind captain --repo sample >/dev/null \
    || fail "could not create the older call"
  tasks_in "$home" hold sample-old-call --reason "captain must decide" --kind captain >/dev/null \
    || fail "could not hold the older call"
  out=$(run_captain "$home" complete "$other" sample-old-call) \
    || fail "complete refused an older hold with no recorded origin"
  assert_contains "$out" "no recorded origin on: sample-old-call" \
    "an older hold with no recorded origin was not flagged"
  pass "complete refuses an entry held for another origin and flags one with none recorded"
}

test_hold_origins_follow_backend_holds() {
  local home phase timing failure id shown origin out parent channel occurrence until_args=() until_field
  for phase in new active released; do
    for timing in plain dated; do
      home=$(make_home "origin-failure-$phase-$timing")
      parent=$(make_home "origin-parent-$phase-$timing")
      channel="$parent/state/origin-mate.status"
      occurrence=1
      [ "$phase" != released ] || occurrence=2
      id=sample-call
      for origin in origin-a origin-b; do
        tasks_in "$home" add "$origin" "Review $origin" --kind scout --repo sample >/dev/null \
          || fail "could not create $origin"
        write_origin_meta "$home" "$origin"
      done
      if [ "$phase" != new ]; then
        run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
          --origin origin-a >/dev/null || fail "could not establish the original association"
      fi
      if [ "$phase" = released ]; then
        printf 'Release this work.\n' > "$home/answer.txt"
        run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
          || fail "could not release the original hold"
      fi
      cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = origin-b ] && [ -f "$FM_HOME/fail-lookup" ]; then
  : > "$FM_HOME/lookup-refused"
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "${1:-}" = update ]; then
  previous=''
  for arg in "$@"; do
    if [ "$previous" = --body-file ] && grep -qx 'Captain hold origin: origin-b' "$arg"; then
      [ -f "$FM_HOME/backend-held" ] || exit 8
      "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-origin-write" || exit $?
      if [ -f "$FM_HOME/fail-write" ]; then
        channel="$(sed -n 's/^parent_home=//p' "$FM_HOME/.fm-secondmate-parent")/state/origin-mate.status"
        [ ! -f "$channel" ] || cp "$channel" "$FM_HOME/parent-before-origin-write"
        : > "$FM_HOME/write-refused"
        exit 9
      fi
    fi
    previous=$arg
  done
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  if [ -f "$FM_HOME/fail-hold" ]; then
    : > "$FM_HOME/hold-refused"
    exit 9
  fi
  "$REAL_TASKS_AXI" "$@" || exit $?
  : > "$FM_HOME/backend-held"
  exit 0
fi
exec "$REAL_TASKS_AXI" "$@"
SH
      chmod +x "$home/fakebin/tasks-axi"
      until_args=()
      [ "$timing" != dated ] || until_args=(--until 2099-01-01)
      for failure in lookup hold write; do
        if [ "$failure" = write ]; then
          printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
            > "$home/.fm-secondmate-parent"
          printf 'origin-mate\n' > "$home/.fm-secondmate-home"
        fi
        : > "$home/fail-$failure"
        if run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for B" \
          --origin origin-b ${until_args[@]+"${until_args[@]}"} > "$home/hold.out" 2> "$home/hold.err"; then
          fail "$phase $timing hold succeeded despite an origin $failure failure"
        fi
        assert_present "$home/$failure-refused" "the failure did not reach the origin $failure"
        if [ "$failure" = lookup ]; then
          assert_absent "$home/before-backend-hold" "$phase $timing origin lookup failure reached the backend hold"
        else
          assert_present "$home/before-backend-hold" "$phase $timing failure never reached the backend hold"
          assert_no_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
            "the backend hold saw the new association before succeeding"
          rm "$home/before-backend-hold"
        fi
        if [ "$failure" = write ]; then
          assert_present "$home/backend-held" "the origin write preceded backend success"
          assert_grep 'held: yes' "$home/before-origin-write" "the origin write did not follow a live hold"
          assert_grep 'hold_kind: captain' "$home/before-origin-write" "the origin write did not follow a captain hold"
          assert_present "$home/parent-before-origin-write" "the verified hold was not published before the origin write"
          until_field=''
          [ "$timing" != dated ] || until_field=' [until=2099-01-01]'
          assert_grep "needs-decision [key=captain-hold-$id-$occurrence]$until_field: captain hold $id: Choose for B" \
            <(sed -E 's/ \[at=[0-9]+\]//' "$home/parent-before-origin-write") \
            "the origin-write failure stranded the hold without its parent event"
          assert_equals 1 "$(grep -Fc "needs-decision [key=captain-hold-$id-$occurrence]" "$channel")" \
            "the failed origin write did not publish exactly one parent decision"
        fi
        shown=$(tasks_in "$home" show "$id" --full)
        assert_not_contains "$shown" 'Captain hold origin: origin-b' \
          "$phase $timing origin $failure failure published the new association"
        if [ "$phase" = active ] || [ "$failure" = write ]; then
          assert_contains "$shown" 'held: yes' "an origin $failure failure lost the successful hold"
        else
          assert_contains "$shown" 'held: no' "$phase $timing origin $failure failure left the task held"
        fi
        if [ "$phase" != new ]; then
          assert_contains "$shown" 'Captain hold origin: origin-a' \
            "$phase $timing origin $failure failure lost the original association"
        fi
        rm "$home/fail-$failure"
        rm -f "$home/backend-held" "$home/before-origin-write"
        if [ "$phase" = new ] && [ "$failure" = write ]; then
          out=$(run_captain "$home" complete origin-b "$id") \
            || fail "the unrecorded successful hold was not durable"
          assert_contains "$out" "no recorded origin on: $id" "the unrecorded hold was claimed to have an origin"
          run_captain "$home" verify origin-b >/dev/null || fail "the unrecorded hold could not verify"
          continue
        fi
        if [ "$phase" = new ] && run_captain "$home" complete origin-a "$id" \
          > "$home/unrelated.out" 2> "$home/unrelated.err"; then
          fail "$timing origin $failure failure satisfied an unrelated inventory"
        fi
        if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
          fail "$phase $timing origin $failure failure satisfied completion for B"
        fi
        printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
        if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
          fail "$phase $timing origin $failure failure verified an inventory for B"
        fi
        if [ "$phase" != new ]; then
          run_captain "$home" complete origin-a "$id" >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated completion for A"
          run_captain "$home" verify origin-a >/dev/null \
            || fail "$phase $timing origin $failure failure invalidated verification for A"
        fi
      done
      run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
        ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "$phase $timing successful retry failed"
      assert_present "$home/before-backend-hold" "the successful retry did not reach the backend hold"
      shown=$(cat "$home/before-backend-hold")
      assert_not_contains "$shown" 'Captain hold origin: origin-b' "the backend hold ran with the new association already published"
      if [ "$phase" != new ]; then
        assert_contains "$shown" 'Captain hold origin: origin-a' "the backend hold lost the old association before succeeding"
      fi
      assert_grep 'held: yes' "$home/before-origin-write" "the successful origin write preceded a live hold"
      shown=$(tasks_in "$home" show "$id" --full)
      assert_contains "$shown" 'held: yes' "the successful retry did not hold the task"
      assert_contains "$shown" 'Captain hold origin: origin-b' "a successful hold lost its association"
      assert_not_contains "$shown" 'Captain hold origin: origin-a' "a successful hold retained the old association"
      assert_equals 1 "$(grep -Fc "needs-decision [key=captain-hold-$id-$occurrence]" "$channel")" \
        "retrying the origin write duplicated the parent decision"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "a successful hold could not complete B"
      run_captain "$home" verify origin-b >/dev/null || fail "a successful hold could not verify B"
      if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/old-origin.err"; then
        fail "a successful reassociation still certified A"
      fi
    done
  done
  pass "new, active, and released holds publish origins after backend success with and without deferral"
}

test_interrupted_origin_move_does_not_inherit_the_previous_answer() {
  local home id=sample-moved-call shown phase failure o rc until_args=()
  for phase in active expired released-replay released-done; do
    for failure in refused interrupted; do
      home=$(make_home "interrupted-origin-move-$phase-$failure")
      for o in origin-a origin-b; do
        tasks_in "$home" add "$o" "Review $o" --kind scout --repo sample >/dev/null \
          || fail "could not create $o"
        write_origin_meta "$home" "$o"
      done
      run_captain "$home" hold "$id" --title "Separate call" --reason "Choose for A" \
        --origin origin-a >/dev/null || fail "could not hold the call for A"
      printf 'Release this work.\n' > "$home/answer.txt"
      run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
        || fail "could not release the call for A"
      until_args=()
      [ "$phase" != expired ] || until_args=(--until 2000-01-01)
      case "$phase" in
        active|expired)
          run_captain "$home" hold "$id" --reason "Choose again for A" --origin origin-a \
            ${until_args[@]+"${until_args[@]}"} >/dev/null || fail "could not re-hold the call for A"
          ;;
      esac
      run_captain "$home" complete origin-a "$id" >/dev/null \
        || fail "the genuine call for A did not complete A"

      cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_HOME/hold-refused" ] && [ "${1:-}" = update ]; then
  : > "$FM_HOME/restore-refused"
  exit 9
fi
if [ "${1:-}" = hold ] && [ "${2:-}" != --help ]; then
  "$REAL_TASKS_AXI" show "$2" --full > "$FM_HOME/before-backend-hold" || exit $?
  : > "$FM_HOME/hold-refused"
  if [ -f "$FM_HOME/interrupt-hold" ]; then
    kill -TERM "$(cat "$FM_HOME/hold-pid")"
  fi
  exit 9
fi
exec "$REAL_TASKS_AXI" "$@"
SH
      chmod +x "$home/fakebin/tasks-axi"
      rc=0
      if [ "$failure" = interrupted ]; then
        : > "$home/interrupt-hold"
        PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
          FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
          FM_CONFIG_OVERRIDE="$home/config" bash -c \
          'printf "%s\n" "$$" > "$FM_HOME/hold-pid"; exec "$@"' _ \
          "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason "Choose for B" --origin origin-b \
          > "$home/hold.out" 2> "$home/hold.err" || rc=$?
        [ "$rc" -eq 143 ] || fail "the hold was not interrupted by TERM: $rc"
        assert_absent "$home/restore-refused" "an interrupted hold attempted restoration"
      else
        run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b \
          > "$home/hold.out" 2> "$home/hold.err" || rc=$?
        [ "$rc" -ne 0 ] || fail "the hold succeeded although the backend refused it"
        assert_present "$home/restore-refused" "the refused hold did not attempt restoration"
      fi
      assert_present "$home/hold-refused" "the failure did not reach the backend hold"
      assert_no_grep 'Captain hold origin: origin-b' "$home/before-backend-hold" \
        "the move published B before the backend hold"
      shown=$(tasks_in "$home" show "$id" --full)
      assert_contains "$shown" 'Captain hold origin: origin-a' "the failed move lost A's association"
      assert_not_contains "$shown" 'Captain hold origin: origin-b' "the failed move published B's association"
      assert_contains "$shown" 'Captain hold set:' "the fixture did not retain the uncommitted stamp"
      assert_contains "$shown" 'Release this work.' "the failed move lost the earlier answer"
      if [ "$phase" = active ]; then
        assert_contains "$shown" 'held: yes' "the failed move lifted A's active hold"
      else
        assert_contains "$shown" 'held: no' "the failed move created a live hold"
      fi
      if [ "$phase" = expired ]; then
        assert_contains "$shown" 'hold_kind: captain' "the expired fixture lost A's captain annotations"
      fi
      rm "$home/fakebin/tasks-axi"

      if run_captain "$home" complete origin-b "$id" > "$home/complete.out" 2> "$home/complete.err"; then
        fail "complete accepted the previous call for B"
      fi
      assert_no_grep "decisions_reviewed=1" "$home/state/origin-b.meta" \
        "the refused completion recorded an attestation for B"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$id" >> "$home/state/origin-b.meta"
      if run_captain "$home" verify origin-b > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted the previous call for B"
      fi
      case "$phase" in
        released-*)
          if run_captain "$home" complete origin-a "$id" >/dev/null 2> "$home/incomplete.err"; then
            fail "the verification boundary accepted a released answer beneath an incomplete hold"
          fi
          assert_grep "newer hold never completed" "$home/incomplete.err" "the stamp guard did not refuse the incomplete hold"
          if run_captain "$home" verify origin-a >/dev/null 2> "$home/incomplete-verify.err"; then
            fail "verify accepted a released answer beneath an incomplete hold"
          fi
          if [ "$phase" = released-replay ]; then
            run_captain "$home" answer "$id" --release --decision-file "$home/answer.txt" >/dev/null \
              || fail "could not replay A's earlier answer"
          else
            tasks_in "$home" "done" "$id" --keep 1 >/dev/null || fail "could not complete the released work"
          fi
          shown=$(tasks_in "$home" show "$id" --full)
          assert_contains "$shown" 'Captain hold origin: origin-a' "the subsequent transition changed A's association"
          if run_captain "$home" complete origin-b "$id" >/dev/null 2> "$home/transition-complete.err"; then
            fail "$phase certified B after a failed move"
          fi
          assert_grep "was held for origin origin-a, not origin-b" "$home/transition-complete.err" \
            "the transition did not refuse B on origin provenance"
          if run_captain "$home" verify origin-b >/dev/null 2> "$home/transition-verify.err"; then
            fail "$phase verified B after a failed move"
          fi
          ;;
      esac
      run_captain "$home" complete origin-a "$id" >/dev/null || fail "the surviving call could not complete A"
      run_captain "$home" verify origin-a >/dev/null || fail "the surviving call could not verify A"
      [ "$phase" != released-done ] || continue

      run_captain "$home" hold "$id" --reason "Choose for B" --origin origin-b >/dev/null \
        || fail "the interrupted move could not be completed"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "a held call for B did not complete B"
      printf 'Ship it for B.\n' > "$home/answer-b.txt"
      run_captain "$home" answer "$id" --release --decision-file "$home/answer-b.txt" >/dev/null \
        || fail "could not release the call for B"
      run_captain "$home" complete origin-b "$id" >/dev/null \
        || fail "the genuine answer for B did not complete B"
      run_captain "$home" verify origin-b >/dev/null \
        || fail "the genuine answer for B did not verify B"
    done
  done
  pass "failed and interrupted origin moves cannot inherit active, expired, replayed, or completed calls"
}

test_historical_self_inventory_has_workable_repair() {
  local home origin=sample-review keep=retained-call replacement=repair-call meta before out
  home=$(make_home historical-self-inventory)
  run_captain "$home" hold "$origin" --title "Old review call" --reason "Choose" >/dev/null \
    || fail "could not create the historical origin"
  write_origin_meta "$home" "$origin"
  for out in "$keep" "$replacement"; do
    run_captain "$home" hold "$out" --title "Call $out" --reason "Choose" --origin "$origin" >/dev/null \
      || fail "could not create $out"
  done
  meta="$home/state/$origin.meta"
  printf 'decisions_reviewed=1\ndecision_keys=%s,%s\n' "$origin" "$keep" >> "$meta"
  before=$(cat "$meta")
  for out in "$replacement" --none; do
    if run_captain "$home" complete "$origin" "$out" > "$home/complete.out" 2> "$home/complete.err"; then
      fail "complete accepted the historical self-inventory"
    fi
    assert_grep "historical decision_keys in $meta still contains $origin" "$home/complete.err" \
      "the historical refusal did not identify the persisted entry"
    assert_grep 'replace only' "$home/complete.err" "the refusal omitted the repair instruction"
  done
  if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
    fail "verify accepted the historical self-inventory"
  fi
  assert_grep "historical decision_keys in $meta still contains $origin" "$home/verify.err" \
    "verify omitted the historical repair instruction"
  assert_equals "$before" "$(cat "$meta")" "refusing a historical inventory changed it"
  sed "s/^decision_keys=$origin,$keep$/decision_keys=$replacement,$keep/" "$meta" > "$meta.repaired"
  mv "$meta.repaired" "$meta"
  run_captain "$home" complete "$origin" "$replacement" >/dev/null \
    || fail "the documented historical repair did not allow completion"
  run_captain "$home" verify "$origin" >/dev/null || fail "the repaired inventory did not verify"
  assert_equals "decision_keys=$replacement,$keep" "$(grep '^decision_keys=' "$meta" | tail -1)" \
    "repair lost a sibling inventory entry"
  if run_captain "$home" complete "$origin" "$origin" >/dev/null 2> "$home/self.err"; then
    fail "repair allowed a new self-inventory"
  fi
  pass "historical self-inventories name a workable repair that preserves sibling entries"
}

test_inventory_compares_backend_identities() {
  local home origin entry shown before
  home=$(make_home backend-identities)
  run_captain "$home" hold fm-o --title "Origin" --reason "Choose" >/dev/null \
    || fail "could not create the canonical origin"
  tasks_in "$home" add fm-other "Other origin" --kind scout --repo sample >/dev/null \
    || fail "could not create the other origin"
  cat > "$home/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = show ] && [ "${2:-}" = o ] && [ -f "$FM_HOME/fail-identity" ]; then
  printf 'error: origin read failed\ncode: READ_FAILED\n' >&2
  exit 2
fi
if [ "$#" -ge 2 ]; then
  case "$2" in
    o|call|other) set -- "$1" "fm-$2" "${@:3}" ;;
  esac
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  for origin in fm-o o; do
    for entry in fm-o o; do
      write_origin_meta "$home" "$origin"
      if run_captain "$home" complete "$origin" "$entry" > "$home/self.out" 2> "$home/self.err"; then
        fail "complete accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'cannot be its own captain-call inventory entry' "$home/self.err" \
        "the alias refusal did not identify self-inventory"
      printf 'decisions_reviewed=1\ndecision_keys=%s\n' "$entry" >> "$home/state/$origin.meta"
      if run_captain "$home" verify "$origin" > "$home/verify.out" 2> "$home/verify.err"; then
        fail "verify accepted aliased self-inventory $origin/$entry"
      fi
      assert_grep 'historical decision_keys' "$home/verify.err" "the alias repair diagnostic was missing"
    done
    write_origin_meta "$home" "$origin"
  done
  run_captain "$home" hold fm-call --title "Separate call" --reason "Choose" --origin o >/dev/null \
    || fail "could not hold a call using the origin alias"
  shown=$(tasks_in "$home" show fm-call --full)
  assert_contains "$shown" 'Captain hold origin: fm-o' "hold did not store the backend origin identity"
  printf '%s\n' "$shown" | sed -n 's/^  body: //p' | jq -r . \
    | sed 's/^Captain hold origin: fm-o$/Captain hold origin: o/' > "$home/legacy-origin.txt"
  tasks_in "$home" update fm-call --body-file "$home/legacy-origin.txt" >/dev/null \
    || fail "could not create a legacy stored alias"
  for origin in fm-o o; do
    for entry in fm-call call; do
      run_captain "$home" complete "$origin" "$entry" >/dev/null \
        || fail "complete refused equivalent origin spellings for $origin/$entry"
      run_captain "$home" verify "$origin" >/dev/null \
        || fail "verify refused equivalent origin spellings for $origin/$entry"
    done
  done
  for origin in fm-other other; do
    write_origin_meta "$home" "$origin"
    if run_captain "$home" complete "$origin" call > "$home/other.out" 2> "$home/other.err"; then
      fail "complete accepted another origin through $origin"
    fi
    assert_grep "was held for origin o, not $origin" "$home/other.err" "the alias mismatch was not identified"
    printf 'decisions_reviewed=1\ndecision_keys=call\n' >> "$home/state/$origin.meta"
    if run_captain "$home" verify "$origin" >/dev/null 2> "$home/other-verify.err"; then
      fail "verify accepted another origin through $origin"
    fi
  done
  : > "$home/fail-identity"
  before=$(cat "$home/state/o.meta")
  if run_captain "$home" complete o fm-call >/dev/null 2> "$home/read.err"; then
    fail "an unreadable backend identity was treated as an absent origin"
  fi
  assert_grep 'could not resolve the backend identity of o' "$home/read.err" "the identity read failure was hidden"
  assert_equals "$before" "$(cat "$home/state/o.meta")" "a failed identity read changed the inventory"
  rm "$home/fail-identity"
  write_origin_meta "$home" report-only
  run_captain "$home" hold report-call --title "Report call" --reason "Choose" --origin report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not record a call"
  run_captain "$home" complete report-only report-call >/dev/null \
    || fail "an origin with metadata but no backlog row could not complete"
  run_captain "$home" verify report-only >/dev/null \
    || fail "an origin with metadata but no backlog row could not verify"
  pass "completion and verification compare backend identities for entries and current or stored origins"
}

# Done retention moves an answered captain call into the Done archive, where
# tasks-axi no longer shows it; the completion gate must still count the
# archived answer as durable, and must still refuse an archived close that
# carries no captain answer or an attested call found nowhere.
test_archived_answered_hold_still_satisfies_the_gate() {
  local home id archive
  home=$(make_home archived-answer)
  id=sample-archived-review
  archive="$home/data/done-archive.md"
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the archived sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the archived-answer origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# Archived sample review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  run_captain "$home" hold sample-archived-call --title "Choose the archived option" \
    --reason "captain archived choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  run_captain "$home" complete "$id" sample-archived-call >/dev/null \
    || fail "completion failed before the answer"
  printf 'Captain chose the archived option.\n' > "$home/archived-decision.txt"
  run_captain "$home" answer sample-archived-call --decision-file "$home/archived-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"
  run_captain "$home" verify "$id" >/dev/null \
    || fail "the answered captain call did not verify before retention"

  perl -0pi -e 's/done_keep = 10/done_keep = 0/' "$home/.tasks.toml"
  tasks_in "$home" add sample-archived-trigger "Trigger Done retention" --kind ship --repo sample >/dev/null
  tasks_in "$home" "done" sample-archived-trigger >/dev/null \
    || fail "could not trigger Done retention"
  assert_grep "sample-archived-call" "$archive" "Done retention did not archive the answered call"
  if tasks_in "$home" show sample-archived-call >/dev/null 2>&1; then
    fail "the archived call is still shown from the live backlog, so the fixture reproduces nothing"
  fi

  run_captain "$home" verify "$id" >/dev/null 2> "$home/archived-verify.err" \
    || fail "verify refused an answered call Done retention archived: $(cat "$home/archived-verify.err")"
  run_captain "$home" complete "$id" sample-archived-call >/dev/null 2> "$home/archived-complete.err" \
    || fail "complete refused an answered call Done retention archived: $(cat "$home/archived-complete.err")"
  run_teardown "$home" "$id" >/dev/null 2> "$home/archived-teardown.err" \
    || fail "teardown refused a scout whose answered call was archived: $(cat "$home/archived-teardown.err")"

  id=sample-archived-unanswered-review
  mkdir -p "$home/data/$id"
  tasks_in "$home" add "$id" "Investigate the unanswered sample" --kind scout --repo sample --start >/dev/null
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  run_captain "$home" hold sample-archived-unanswered-call --title "Choose the unanswered option" \
    --reason "captain unanswered choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the unanswered captain-held task"
  run_captain "$home" complete "$id" sample-archived-unanswered-call >/dev/null \
    || fail "completion failed for the unanswered hold"
  tasks_in "$home" "done" sample-archived-unanswered-call >/dev/null \
    || fail "could not close the unanswered hold out of band"
  assert_grep "sample-archived-unanswered-call" "$archive" \
    "Done retention did not archive the unanswered close"
  if run_captain "$home" verify "$id" > "$home/unanswered-verify.out" 2> "$home/unanswered-verify.err"; then
    fail "verify accepted an archived captain call closed with no recorded answer"
  fi
  if run_teardown "$home" "$id" > "$home/unanswered-teardown.out" 2> "$home/unanswered-teardown.err"; then
    fail "teardown proceeded while an archived captain call had no recorded answer"
  fi
  assert_present "$home/state/$id.meta" "refused teardown removed investigation metadata"

  printf 'decisions_reviewed=1\ndecision_keys=sample-never-held-call\n' >> "$home/state/$id.meta"
  if run_captain "$home" verify "$id" > "$home/missing-verify.out" 2> "$home/missing-verify.err"; then
    fail "verify accepted an attested captain call that exists nowhere"
  fi
  assert_grep "sample-never-held-call" "$home/missing-verify.err" \
    "the refusal did not name the missing captain call"
  pass "an answered captain call archived by Done retention still satisfies the completion gate"
}

# The archive location is not always beside the backlog: tasks-axi honours a
# [markdown] archive set only in the user-level $HOME/.tasks-axi/config.toml, and
# resolves a relative value against the backlog root. The completion gate must
# resolve it the same way, or an answered call retention moved there reads as
# absent and teardown is refused.
test_archived_answer_in_a_user_configured_archive_satisfies_the_gate() {
  local home axi_home archive id
  home=$(make_home archived-answer-userconfig)
  axi_home="$home/axi-home"
  mkdir -p "$axi_home/.tasks-axi"
  # Root config sets no archive, so the location comes only from the user config.
  cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
done_keep = 10
EOF
  cat > "$axi_home/.tasks-axi/config.toml" <<'EOF'
[markdown]
archive = "data/relocated-done-archive.md"
EOF
  archive="$home/data/relocated-done-archive.md"
  id=sample-userconfig-review
  mkdir -p "$home/data/$id"
  HOME="$axi_home" tasks_in "$home" add "$id" "Investigate the user-config sample" --kind scout --repo sample --start >/dev/null \
    || fail "could not create the user-config origin"
  write_origin_meta "$home" "$id"
  printf 'done: report complete\n' > "$home/state/$id.status"
  printf '# User-config sample review\n\nOne captain choice remains.\n' > "$home/data/$id/report.md"
  HOME="$axi_home" run_captain "$home" hold sample-userconfig-call --title "Choose the relocated option" \
    --reason "captain relocated choice pending" --repo sample --origin "$id" >/dev/null \
    || fail "could not register the captain-held task"
  HOME="$axi_home" run_captain "$home" complete "$id" sample-userconfig-call >/dev/null \
    || fail "completion failed before the answer"
  printf 'Captain chose the relocated option.\n' > "$home/userconfig-decision.txt"
  HOME="$axi_home" run_captain "$home" answer sample-userconfig-call --decision-file "$home/userconfig-decision.txt" >/dev/null \
    || fail "answer could not close the captain-held task"

  perl -0pi -e 's/done_keep = 10/done_keep = 0/' "$home/.tasks.toml"
  HOME="$axi_home" tasks_in "$home" add sample-userconfig-trigger "Trigger Done retention" --kind ship --repo sample >/dev/null
  HOME="$axi_home" tasks_in "$home" "done" sample-userconfig-trigger >/dev/null \
    || fail "could not trigger Done retention"
  assert_present "$archive" "Done retention did not write the user-configured archive"
  assert_grep "sample-userconfig-call" "$archive" \
    "Done retention did not archive the answered call to the user-configured location"
  if HOME="$axi_home" tasks_in "$home" show sample-userconfig-call >/dev/null 2>&1; then
    fail "the archived call is still shown from the live backlog, so the fixture reproduces nothing"
  fi

  HOME="$axi_home" run_captain "$home" verify "$id" >/dev/null 2> "$home/userconfig-verify.err" \
    || fail "verify refused an answered call archived to the user-configured location: $(cat "$home/userconfig-verify.err")"
  HOME="$axi_home" run_captain "$home" complete "$id" sample-userconfig-call >/dev/null 2> "$home/userconfig-complete.err" \
    || fail "complete refused an answered call archived to the user-configured location: $(cat "$home/userconfig-complete.err")"
  HOME="$axi_home" run_teardown "$home" "$id" >/dev/null 2> "$home/userconfig-teardown.err" \
    || fail "teardown refused a scout whose answered call was archived to the user-configured location: $(cat "$home/userconfig-teardown.err")"
  pass "an answered captain call archived to a user-configured location still satisfies the completion gate"
}


test_hold_origins_follow_backend_holds
test_interrupted_origin_move_does_not_inherit_the_previous_answer
test_historical_self_inventory_has_workable_repair
test_inventory_compares_backend_identities
test_origin_is_never_its_own_inventory_entry
test_complete_refuses_an_entry_held_for_another_origin
test_hold_decodes_a_bare_scalar_body_without_the_nonref_default
test_retained_body_keeps_its_utf8_bytes
test_teardown_never_closes_a_captain_held_task
test_retained_row_artifacts_survive_captain_answers
test_interrupted_cleanup_keeps_the_captain_call_recoverable
test_answer_before_cleanup_replay_preserves_the_retained_report
test_answer_before_cleanup_replay_notes_a_retained_gerrit_change
test_unusable_pending_close_record_names_its_reason
test_relocated_report_does_not_wedge_an_answer_before_replay
test_teardown_retains_captain_calls_in_a_relocated_backlog
test_teardown_retains_a_gerrit_captain_call_with_its_change_url
test_merge_approval_releases_before_zero_done_retention
test_pr_merge_entrypoint_refuses_a_captain_held_task
test_local_merge_entrypoint_refuses_a_captain_held_task
test_pr_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_local_merge_entrypoint_separates_an_unreadable_record_from_an_absent_one
test_merge_entrypoints_validate_identity_and_state_before_locking
test_merge_entrypoints_refuse_a_reused_task_incarnation
test_merge_entrypoints_serialize_forced_teardown_before_task_reads
test_released_merge_passes_the_entrypoint_and_lands
test_teardown_refuses_a_ship_when_the_captain_hold_cannot_be_read
test_archived_answered_hold_still_satisfies_the_gate
test_archived_answer_in_a_user_configured_archive_satisfies_the_gate
