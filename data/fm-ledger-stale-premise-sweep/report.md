# Ledger stale-premise sweep

## Scope and inventory

The isolated worktree contains `data/backlog.md`, but `data/learnings.md` and `data/captain.md` are absent. The latter files are private home records and cannot be read from this worktree. The requested inventory is therefore limited to the two backlog items visible here; it is not a complete three-file inventory, and absence is not evidence that either private file is empty.

| Location | Claim / entry | Volatile category | Dependency and evidence in the available record |
| --- | --- | --- | --- |
| `data/backlog.md:5-26` | `fm-review-triage-followups`, describing three issues triaged out of a PR. | Other implementation / review state; code-path behavior; possible future implementation. | Depends on the referenced secondmate runtime-state PR and current code/tests. The text attributes the items to a review gate and says they were triaged out; no PR URL, current branch state, or verification date is recorded. Subclaims: `bin/fm-busy-event.sh` marker ordering and bounded stale evidence (`:10-17`); `bin/fm-pending-reply-lib.sh` process-id temp collision after failed copy (`:18-22`); overlapping symlink tests (`:23-24`). |
| `data/backlog.md:28-29` | `fm-pending-reply-test-shape`, asserting four test cases were dropped by shared-fixture work and suite passes 18/0. | Other implementation / review state; test result. | Depends on the runtime-state PR's current diff and test suite. The recorded evidence is review finding R-032, named test file/case descriptions, and a suite result with no run date or commit identity. |

Available-record classification count: 2 backlog entries (both depend on other implementation/review state); 0 explicit version-number claims; 0 filesystem-path-existence claims (paths name code/test locations, not claims of an external data path); 0 external-interface behavior claims. The first item has two code-behavior assertions and one test-overlap assertion; the second has a test-history and suite-result assertion. This count excludes the unavailable `learnings.md` and `captain.md`, so it is not the complete count requested.

## Proposed format and grep criterion

Proposed optional marker: add `Review premise: <what fact this depends on>` inside an entry when a statement may become false. Reuse a date field only when the existing record format already gives that field deadline/expiry semantics; do not assign expiry meaning to a creation date or introduce date syntax.

The requested completeness criterion cannot be met with the current formats. The marker can be found by one grep, but grep alone cannot identify all entries without the marker or determine whether assorted existing dates are deadlines and overdue. The relevant records are multiline prose without a proven uniform one-line entry boundary, and no common explicit expiry field was established. The example search `grep -nH 'Review premise:' data/backlog.md data/learnings.md data/captain.md` only finds marked premises; it is not a complete stale-or-unmarked query. Accordingly, no claim is made that the proposed convention satisfies the one-grep criterion. Alternative: establish a common, explicit entry boundary and deadline semantics first, then validate that a single grep expression returns both expired and premise-missing entries before adopting it. No tool or automation is proposed.

The pre-dispatch check to include in the convention is: “凡从台账取一条旧事实作为派工前提，必须先做一次现场核验并在交付里写明‘我复现过／我没复现出’。”

## Proposed private-ledger edits (not performed)

改写由主家执行. No private ledger has been edited. These are the limited candidate additions suggested by the available evidence; preserve each original judgment and its attribution/evidence while adding the condition under which it can expire:

1. `data/backlog.md:10-17` — original assertion: failed removal of the live-progress marker can leave stale in-turn evidence until the next clean transition, delaying escalation by one stall interval; the ordering was previously chosen by an earlier gate round. Dependency: current `bin/fm-busy-event.sh` implementation and the cited earlier gate decision. Suggested condition: `Review premise: this behavior and ordering remain present in the current bin/fm-busy-event.sh and have not been superseded by a later gate decision; verify against the target branch before using this as an open follow-up.`
2. `data/backlog.md:18-22` — original assertion: a process-id-named expiry audit temp can block later attempts after failed copy, with the issue limited to a failed copy and no data loss; proposed fix is unique per-attempt names plus abandoned-temp sweep. Dependency: current `bin/fm-pending-reply-lib.sh` temp naming and cleanup implementation. Suggested condition: `Review premise: the current implementation still uses process-id-only temp naming without per-attempt cleanup; recheck the code before treating this as unfixed.`
3. `data/backlog.md:23-24` — original assertion: two symlinked-record tests overlap and consolidation would be readability-only. Dependency: current `tests/fm-pending-reply.test.sh` test inventory. Suggested condition: `Review premise: the two tests still exist and overlap in the current test file; inspect both tests before scheduling consolidation.`
4. `data/backlog.md:28-29` — original assertion: review finding R-032 identified four dropped cases; suite passes 18/0 and the assertions were meaningful. Dependency: current PR/diff history and current `tests/fm-classify-decision-key.test.sh` behavior. Suggested condition: `Review premise: R-032's cases remain absent from the current test file and do not conflict with the current fold contract; verify the diff and run the relevant suite before scheduling restoration.`

These premises must be checked against authoritative current code/review evidence before applying the candidate text. The available files do not expose the reported four stale-fact examples, so those cannot be individually located or corrected here.

## Changes and omissions

- Added `docs/ledger-freshness.md` with the optional premise marker, the limits of grep-only completeness, and the required pre-dispatch check.
- No existing ledger claims were rewritten because private files were unavailable and the task authority now assigns private edits to the main home. The four candidate entries above are recommendations only; no historical content was deleted or silently changed.
- No independent review was performed. The requested full inventory, classification across all three files, verification of the historical examples, and edits to private records remain outstanding because the two private source files are absent from this isolated worktree.
- The document's tracked change is a direct-PR deliverable under the revised instruction. Its scope is limited to the format convention; it does not change `AGENTS.md`, scripts, schedules, project business code, or any captain preference.
