# Teardown merge-claim change: rigor disclosure and per-item reconciliation

## Rigor disclosure (read this before trusting the change)

1. **This change has not been through an independent code review.** The reason is mechanical, not a choice to save effort: this repository's `no-mistakes` review step enforces an absolute 30-minute wall clock, and it killed the review analyzer pass repeatedly on this same task (three runs, the last two at the review step, each reported by the tool itself as `step review failed: agent fix reached its absolute wall-clock limit after 30m0s`).
2. **What stands in for that review here**: the per-item reconciliation table below (each behavior the change claims, where the code enforces it, which test pins it, and the result) plus a full local run of the three suites this change touches - `tests/fm-teardown.test.sh` 149/149, `tests/fm-backlog-atomicity.test.sh` 106/106, `tests/fm-captain-hold-lifecycle.test.sh` 71/71, all with zero failures, on the commit that carries this file.
3. **That is not equivalent to external review.** A reviewer who has not written this code will still find policy and ordering questions this table cannot answer, and CI on the pull request is the only mechanical gate that has run against the delivered head.

## What the change does

A backlog row closed by `tasks-axi` renders as `(merged <date>)` whenever its title carries a pull-request link, and no flag or configuration overrides that renderer.
Cleanup used to pass the recorded link unconditionally, so a still-open pull request produced a ledger line claiming a merge that never happened.
Now a merge is recorded only when the run that writes the record read it from the forge, and every other shape records a completion that keeps the link in the body note.

## Per-item reconciliation

| # | Behavior the change claims | Where it is enforced | Test that pins it | Result |
| --- | --- | --- | --- | --- |
| 1 | A close that reads no merge records a completion, and its note keeps the link and the reason | `bin/fm-teardown.sh:1862`, `bin/fm-backlog-transition-lib.sh:598` | `tests/fm-teardown.test.sh:814` `test_teardown_close_never_claims_a_merge_it_did_not_read` | pass |
| 2 | An unreadable pull-request state is not a merge | `bin/fm-teardown.sh:1682` | `tests/fm-teardown.test.sh:973` `test_teardown_close_states_an_unreadable_pr_without_claiming_a_merge` | pass |
| 3 | A merge the forge reports is still recorded, with its link | `bin/fm-teardown.sh:1862` | `tests/fm-teardown.test.sh:954` `test_teardown_records_the_merge_the_forge_confirms` | pass |
| 4 | A close that fails after writing its note keeps the URL, and leaves its record for the retry | `bin/fm-backlog-transition-lib.sh:598` (`fm_backlog_done`) | `tests/fm-teardown.test.sh:862` `test_teardown_close_keeps_the_link_when_the_close_itself_fails` | pass |
| 5 | A verified close drops any *other* link no run verified, noting it instead | `bin/fm-backlog-transition-lib.sh:598` (`FM_BACKLOG_PR_LINK_EXCLUDE` path) | `tests/fm-teardown.test.sh:906` `test_teardown_verified_close_drops_another_link_no_run_verified` | pass |
| 6 | A retained row never carries a link that renders as merged, and its deliverable keeps the URL | `bin/fm-backlog-transition-lib.sh:1052` (`fm_backlog_retain`) | `tests/fm-teardown.test.sh:996` `test_teardown_retain_never_claims_a_merge_it_did_not_read` | pass |
| 7 | An unverified answer close keeps the URL in a body note and removes the structured link | `bin/fm-captain-hold.sh:1257` (`close_answered`) | `tests/fm-captain-hold-lifecycle.test.sh:3393` `test_answer_clears_an_earlier_pr_link_it_did_not_verify` | pass |
| 8 | The answer writes the note first, strips second, closes last, and a retry neither loses nor duplicates it | `bin/fm-captain-hold.sh:1257`, `bin/fm-backlog-transition-lib.sh:872` | `tests/fm-captain-hold-lifecycle.test.sh:3521` `test_answer_survives_a_failed_close_without_losing_the_link` | pass |
| 9 | A merge verified before the retention landed is still recorded by the later answer | `bin/fm-captain-hold.sh:1199`, `bin/fm-backlog-transition-lib.sh:925` | `tests/fm-captain-hold-lifecycle.test.sh:3476` `test_answer_keeps_a_merge_after_the_retention_landed` | pass |
| 10 | A verified merge is kept when the answer arrives before the retention lands | `bin/fm-captain-hold.sh:1199` | `tests/fm-captain-hold-lifecycle.test.sh:3425` `test_answer_keeps_a_merge_the_retention_verified` | pass |
| 11 | A merge fact that names another link cannot vouch for this delivery | `bin/fm-backlog-transition-lib.sh:1001` (`fm_backlog_row_carries_pr_link`) | `tests/fm-captain-hold-lifecycle.test.sh:3574` `test_answer_ignores_a_merge_fact_for_another_link` | pass |
| 12 | A retained record that carried its completion as a note is applied, not dropped | `bin/fm-captain-hold.sh:1199` (`--note` arm) | `tests/fm-captain-hold-lifecycle.test.sh:3607` `test_answer_records_the_note_a_retained_record_carried` | pass |
| 13 | A recorded link no run verified is noted, never closed as a merge | `bin/fm-captain-hold.sh:1199`, `bin/fm-backlog-transition-lib.sh:1655` | `tests/fm-captain-hold-lifecycle.test.sh:3632` `test_answer_downgrades_a_recorded_link_no_run_verified` | pass |
| 14 | A replay closes a verified record as a merge and keeps its link | `bin/fm-backlog-transition-lib.sh:1655` | `tests/fm-backlog-atomicity.test.sh:2062` `test_recovery_replays_a_verified_merge_as_a_merge` | pass |
| 15 | A replay of a record without the verified fact closes as a completion with the historical note | `bin/fm-backlog-transition-lib.sh:1655`, `808` | `tests/fm-backlog-atomicity.test.sh:2118` `test_recovery_replays_a_close_whose_merge_was_never_confirmed`, `2235` `test_recovery_downgrades_an_unverified_recorded_link_on_a_live_row` | pass |
| 16 | Finishing a failed close at session start neither loses nor duplicates its note | `bin/fm-backlog-transition-lib.sh:598` (note dedupe) | `tests/fm-backlog-atomicity.test.sh:2087` `test_recovery_replays_a_failed_close_without_duplicating_its_note` | pass |
| 17 | A record that no longer applies never rewrites the row it names | `bin/fm-backlog-transition-lib.sh:1655` | `tests/fm-backlog-atomicity.test.sh:2646` `test_recovery_a_stale_record_never_touches_the_row` | pass |
| 18 | A verified recorded link is backfilled onto an already-closed row | `bin/fm-backlog-transition-lib.sh:598` | `tests/fm-backlog-atomicity.test.sh:2212` `test_recovery_backfills_a_recorded_link_on_an_already_done_item` | pass |
| 19 | Removing an unverified link leaves no structured link and no URL on the title | `bin/fm-backlog-transition-lib.sh:850` (`fm_backlog_pr_title_strip`) | `tests/fm-captain-hold-lifecycle.test.sh:3393` (title and `links: none` assertions) | pass |

## Suite counts from the run this file was committed with

| Suite | Passed / total |
| --- | --- |
| `tests/fm-teardown.test.sh` | 149 / 149 |
| `tests/fm-backlog-atomicity.test.sh` | 106 / 106 |
| `tests/fm-captain-hold-lifecycle.test.sh` | 71 / 71 |

`bin/fm-lint.sh` (ShellCheck 0.11.0 and actionlint 1.7.12, pinned versions) and `bin/fm-doc-audience-check.sh` also pass at this commit.

## Known limitations

- The pull-request CI on the delivered head is the only check that has seen this code from outside this worktree.
- A stop-state race remains inherent: a row is closed by a separate `tasks-axi` mutation, so no local sequence can make the strip and the close one transaction; the note is written first precisely so the failure window costs no information.
- The narrower questions a reviewer would likely ask - whether a second link should ever be preserved, whether the durable fact should be keyed per link rather than per task - are answered by the shape above and pinned by tests 5 and 11, not settled by external review.
