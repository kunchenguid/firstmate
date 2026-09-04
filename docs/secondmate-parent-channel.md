# Secondmate parent channel

This note records why a secondmate home's captain-facing outcomes are delivered by scripts instead of by the mate model, and which script delivers each one.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The problem

A secondmate is a firstmate in its own home, and nobody reads its chat: the captain and the main firstmate see only what is appended to the parent channel.
On 2026-09-02 four outcomes across two mate homes never reached the captain.
The watcher had delivered the parent's request within a minute each time, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: `AGENTS.md` tells every firstmate to reach the captain and to address the captain in every response, while the charter's return-channel rule is a smaller, later instruction.
The captain's framing of the requirement was: "the root problem is not specific to PRs, right? it looks like any message or outcomes from second mates can miss. we need to make sure our fixes are addressing this in a principled, fundamental way, not surgically treating the symptoms of just this PR update miss."
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## The design

The delivery rule has one sentence: the scripts report facts, the mate reports judgement.
Every captain-facing outcome that leaves durable evidence in the mate home is published on the channel by the script that records that evidence, at record time or on the next supervision poll, and the charter reserves the mate's own appends for judgement.

| Outcome | Durable evidence in the mate home | Published by |
|---|---|---|
| Ship child PR ready | the child's `done:` line, whatever shape its delivery mode's claim grammar gives it ([`bin/fm-done-claim-lib.sh`](../bin/fm-done-claim-lib.sh)); `pr=` in the child's record once registered | `bin/fm-inactive-reconcile.sh` on the next poll with the child's line; `bin/fm-pr-check.sh` at registration with the canonical URL |
| Scout child findings | the child's `done:` line plus `data/<child>/report.md` | `bin/fm-inactive-reconcile.sh` on the next poll, with the report pointer |
| Child failed | the child's `failed:` line | `bin/fm-inactive-reconcile.sh` on the next poll |
| Child decision escalated to the captain | the task held for the captain in the mate backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` |
| PR merged | the merge poll or the mate's own merge | `bin/fm-merge-outcome-lib.sh` |
| Child leaving the home | its final ledger line | `bin/fm-teardown.sh`, which refuses to remove the child while that line is undelivered |
| Child ended silently | terminal current state with a silent ledger | the existing inactive-outcome scan in `bin/fm-inactive-reconcile.sh` |
| Answer to a marked request | a correlated line guarded by the pending-reply record | the existing pending-reply recovery and escalation |
| An outcome that exists only in the mate's reasoning | none | the charter and the `AGENTS.md` carve-outs only |

The ledger delivery reads files only: it calls no harness, no forge, and no current-state reader, so it is identical for every harness and runtime backend.
It publishes what the mate home actually holds, which for a `done:` line includes whether anything established it: a claim that is not verified is published as a `blocked` line carrying `claim=<state>` and the child's own words, so the parent's durable record cannot read `done` while the child's home reports `done-unverified` ([`bin/fm-done-claim-lib.sh`](../bin/fm-done-claim-lib.sh) owns that verdict, read locally from the child's record).
The verdict is part of the event's identity, so a claim established later publishes a corrected line while an unchanged verdict stays deduplicated.
Each delivery is keyed with the first eight hexadecimal characters of its receipt fingerprint and appended at most once by exact line, and the ledger path reuses the inactive scan's per-fingerprint receipts, so a replayed poll or restart cannot deliver an event twice while a genuinely new terminal event is delivered again.
A duplicate line is harmless and a missed one is not, so the mate may still append its own judgement about a delivered outcome, and the parent reads the script's line as the fact and the mate's line as commentary.

## What is deliberately not built

- No mirror of the mate's chat: every firstmate turn contains captain-facing text by mandate, so choosing which sentence is an outcome would itself be model behavior, and every harness exposes turn text differently.
- No threshold escalation of a child's open decision or blocker: a decision the mate escalates is a captain hold, which is published; a decision the mate neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No second watcher or standalone scanner: a lightweight ledger pass runs inside the existing inactive-outcome command on every watcher poll and reuses its receipts and upstream append.
- No orphan lifecycle: teardown refuses instead of removing an undelivered outcome, the same way it refuses on other unlanded conditions.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers the ledger delivery against real ledgers with no harness: immediate done and failed delivery with note, PR, mode, posture, and report pointer, once-only delivery across polls, a line still being appended, the remote route, the yield of the inactive path to a terminal ledger, and the real watcher poll driving it.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers teardown delivering a child's final line and refusing when the channel cannot be written.
`tests/fm-brief.test.sh` pins the charter's channel rule.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: real tmux panes, both real watchers re-armed after each wake, and no model, with every delivered parent line and the parent wake it produced.
