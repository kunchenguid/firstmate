# Teardown merge-claim change: per-item reconciliation

## What the change does

A backlog row closed by `tasks-axi` renders as `(merged <date>)` whenever its title carries a pull-request link, and no flag or configuration overrides that renderer.
Cleanup used to pass the recorded link unconditionally, so a still-open pull request produced a ledger line claiming a merge that never happened.
Now a merge is recorded only when some run read it from the forge and left that verified fact on the pending-close record or the row's durable merge record, and every other shape records a completion that keeps the link in the body note.

## Per-item reconciliation

| # | Behavior the change claims | Where it is enforced | Test that pins it | Result |
| --- | --- | --- | --- | --- |
| 1 | A close that reads no merge records a completion, and its note keeps the link and the reason | `bin/fm-teardown.sh` (`backlog_pr_completion_args`), `bin/fm-backlog-transition-lib.sh` (`fm_backlog_done`) | `tests/fm-teardown.test.sh` `test_teardown_close_never_claims_a_merge_it_did_not_read` | pass |
| 2 | An unreadable pull-request state is not a merge | `bin/fm-teardown.sh` (`pr_merge_fact`) | `tests/fm-teardown.test.sh` `test_teardown_close_states_an_unreadable_pr_without_claiming_a_merge` | pass |
| 3 | A merge the forge reports is still recorded, with its link | `bin/fm-teardown.sh` (`backlog_pr_completion_args`) | `tests/fm-teardown.test.sh` `test_teardown_records_the_merge_the_forge_confirms` | pass |
| 4 | A close that fails after writing its note keeps the URL, and leaves its record for the retry | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_done`) | `tests/fm-teardown.test.sh` `test_teardown_close_keeps_the_link_when_the_close_itself_fails` | pass |
| 5 | A verified close drops any *other* link no run verified, noting it instead | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_done`, `FM_BACKLOG_PR_LINK_EXCLUDE` path) | `tests/fm-teardown.test.sh` `test_teardown_verified_close_drops_another_link_no_run_verified` | pass |
| 6 | A retained row never carries a link that renders as merged, and its deliverable keeps the URL | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_retain`) | `tests/fm-teardown.test.sh` `test_teardown_retain_never_claims_a_merge_it_did_not_read` | pass |
| 7 | An unverified answer close keeps the URL in a body note and removes the structured link | `bin/fm-captain-hold.sh` (`close_answered`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_clears_an_earlier_pr_link_it_did_not_verify` | pass |
| 8 | The answer writes the note first, strips second, closes last, and a retry neither loses nor duplicates it | `bin/fm-captain-hold.sh` (`close_answered`), `bin/fm-backlog-transition-lib.sh` (`fm_backlog_body_append_line`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_survives_a_failed_close_without_losing_the_link`, `test_answer_records_a_composed_note_once` | pass |
| 9 | A merge verified before the retention landed is still recorded by the later answer | `bin/fm-captain-hold.sh` (`apply_pending_retained_artifact`), `bin/fm-backlog-transition-lib.sh` (`fm_backlog_merge_fact_write`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_keeps_a_merge_after_the_retention_landed` | pass |
| 10 | A verified merge is kept when the answer arrives before the retention lands | `bin/fm-captain-hold.sh` (`apply_pending_retained_artifact`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_keeps_a_merge_the_retention_verified` | pass |
| 11 | A merge fact that names another link cannot vouch for this delivery | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_row_carries_pr_link`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_ignores_a_merge_fact_for_another_link` | pass |
| 12 | A retained record that carried its completion as a note is applied, not dropped | `bin/fm-captain-hold.sh` (`apply_pending_retained_artifact`, `--note` arm) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_records_the_note_a_retained_record_carried` | pass |
| 13 | A recorded link no run verified is noted, never closed as a merge | `bin/fm-captain-hold.sh` (`apply_pending_retained_artifact`), `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_marker_replay`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_downgrades_a_recorded_link_no_run_verified` | pass |
| 14 | A replay closes a verified record as a merge and keeps its link | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_marker_replay`) | `tests/fm-backlog-atomicity.test.sh` `test_recovery_replays_a_verified_merge_as_a_merge` | pass |
| 15 | A replay of a record without the verified fact closes as a completion with the historical note | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_marker_replay`, `fm_backlog_pr_link_note`) | `tests/fm-backlog-atomicity.test.sh` `test_recovery_replays_a_close_whose_merge_was_never_confirmed`, `test_recovery_downgrades_an_unverified_recorded_link_on_a_live_row` | pass |
| 16 | Finishing a recorded close or retention at session start neither loses nor duplicates its note | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_marker_replay`, `fm_backlog_retain`, `fm_backlog_body_append_line`) | `tests/fm-backlog-atomicity.test.sh` `test_recovery_replays_a_failed_close_without_duplicating_its_note`, `test_recovery_replays_a_retained_link_note_once` | pass |
| 17 | A record that no longer applies never rewrites the row it names | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_close_marker_replay`) | `tests/fm-backlog-atomicity.test.sh` `test_recovery_a_stale_record_never_touches_the_row` | pass |
| 18 | A verified recorded link is backfilled onto an already-closed row | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_done`) | `tests/fm-backlog-atomicity.test.sh` `test_recovery_backfills_a_recorded_link_on_an_already_done_item` | pass |
| 19 | Removing an unverified link leaves no structured link and no URL on the title | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_pr_title_strip`) | `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_clears_an_earlier_pr_link_it_did_not_verify` (title and `links: none` assertions) | pass |
| 20 | A close, retention, or answer that strips several unverified links keeps every URL in the body note | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_text_names_links`, `fm_backlog_pr_link_downgrade`), `bin/fm-captain-hold.sh` (`close_answered`) | `tests/fm-teardown.test.sh` `test_teardown_close_keeps_every_link_it_downgrades`, `test_teardown_retain_keeps_every_link_it_downgrades`; `tests/fm-backlog-atomicity.test.sh` `test_recovery_keeps_every_link_before_it_strips_the_title`; `tests/fm-captain-hold-lifecycle.test.sh` `test_answer_keeps_every_link_it_downgrades` | pass |
| 21 | A link the gate cannot positively read as a pull request is recorded as an unconfirmed note, including a shape tasks-axi's renderer accepts | `bin/fm-teardown.sh` (`backlog_pr_completion_args`) | `tests/fm-teardown.test.sh` `test_teardown_records_a_renderer_accepted_link_as_an_unconfirmed_note` | pass |
| 22 | A long link that still fits the record stays recordable as an unconfirmed note | `bin/fm-backlog-transition-lib.sh` (`FM_BACKLOG_NOTE_MAX`) | `tests/fm-teardown.test.sh` `test_teardown_records_a_long_but_recordable_pr_link_as_its_unconfirmed_note` | pass |
| 23 | The pending-close record carries ordinary punctuation and still refuses a line break or control byte | `bin/fm-backlog-transition-lib.sh` (`fm_backlog_note_encode`, `fm_backlog_note_decode`, `fm_backlog_close_marker_validate`) | `tests/fm-backlog-atomicity.test.sh` `test_note_codec_carries_punctuation_and_refuses_line_breaks` | pass |

## Refreshing this verification

The per-item table above is the current claim, and each row names the executable test that pins it.
Refresh the table from the repository root with:

```sh
bin/fm-test-run.sh tests/fm-teardown.test.sh
bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh
bin/fm-test-run.sh tests/fm-captain-hold-lifecycle.test.sh
bin/fm-lint.sh
bin/fm-doc-audience-check.sh
```

CI runs every `tests/*.test.sh` in the complete deterministic walk, so the delivered head's per-suite counts belong to that run's log rather than to this page.
The lint version pins are owned by the lint scripts, which print them through `bin/fm-lint.sh --required-version` and `bin/fm-lint-workflows.sh --required-version`.

## Known limitations

- The pull-request CI on the delivered head is the only check that has seen this code from outside this worktree.
- A stop-state race remains inherent: a row is closed by a separate `tasks-axi` mutation, so no local sequence can make the strip and the close one transaction; the note is written first precisely so the failure window costs no information.
- The narrower questions a reviewer would likely ask - whether a second link should ever be preserved, whether the durable fact should be keyed per link rather than per task - are answered by the shape above and pinned by tests 5 and 11, not settled by external review.
