# Project Director parent channel

This note records why a Project Director home's user-facing outcomes are delivered by scripts instead of by the Project Director model, and which script delivers each one.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.

## The problem

A Project Director is a firstmate in its own home, and nobody reads its chat: the user and the main firstmate see only what is appended to the parent channel.
On 2026-09-02 four outcomes across two Project Director homes never reached the user.
The watcher had delivered the parent's request within a minute each time, the Project Director did the work, and then the Project Director addressed "user" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: the Project Director can satisfy the [address rule in `AGENTS.md`](../AGENTS.md#firstmate) in local chat while missing the charter's later return-channel instruction.
The user's framing of the requirement was: "the root problem is not specific to PRs, right? it looks like any message or outcomes from Project Directors can miss. we need to make sure our fixes are addressing this in a principled, fundamental way, not surgically treating the symptoms of just this PR update miss."
A PR-ready report was the observed symptom, but a finding, a decision, a blocker, and a failure all fail the same way, because every one of them depended on the Project Director model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## The design

The delivery rule has one sentence: the scripts report facts, the Project Director reports judgement.
Every user-facing outcome that leaves durable evidence in the Project Director home is published on the channel by the script that records that evidence, at record time or on the next supervision poll, and the charter reserves the Project Director's own appends for judgement.

| Outcome | Durable evidence in the Project Director home | Published by |
|---|---|---|
| Builder child PR ready | the child's `done:` PR ready line, whose accepted spellings the publisher below owns; `pr=` in the child's record once registered | `bin/fm-inactive-reconcile.sh` on the next poll with the child's line; `bin/fm-pr-check.sh` at registration with the canonical URL, or after the green report when [`config/ready-after-green`](configuration.md#pr-ready-line-after-green-configready-after-green) is set |
| Investigator child findings | the child's `done:` line plus `data/<child>/report.md` | `bin/fm-inactive-reconcile.sh` on the next poll, with the report pointer |
| Child failed | the child's `failed:` line | `bin/fm-inactive-reconcile.sh` on the next poll |
| Child decision escalated to the user | the task held for the user in the Project Director backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` |
| PR merged | the merge poll or the Project Director's own merge | `bin/fm-merge-outcome-lib.sh` |
| Child leaving the home | its final ledger line | `bin/fm-teardown.sh`, which refuses to remove the child while that line is undelivered |
| Child ended silently | terminal current state with a silent ledger | the existing inactive-outcome scan in `bin/fm-inactive-reconcile.sh` |
| Answer to a marked request | a correlated line guarded by the pending-reply record | `bin/fm-secondmate-report.sh`, which resolves the parent channel from the Project Director home; the pending-reply guard repairs a line stranded in the local Project Director's same-basename status file before recovery or escalation |
| An outcome that exists only in the Project Director's reasoning | none | the charter and the `AGENTS.md` carve-outs only |

The ledger delivery reads files, plus a local git reachability check on a Builder `done:` with no delivery record yet (`bin/fm-dod-lib.sh`): it calls no harness, no forge, and no current-state reader, so it is identical for every harness and runtime backend.
Each delivery is keyed with the first eight hexadecimal characters of its receipt fingerprint and uses the shared append contract above, and the ledger path reuses the inactive scan's per-fingerprint receipts, so a replayed poll or restart cannot deliver an event twice while a genuinely new terminal event is delivered again.
A duplicate line is harmless and a missed one is not, so the Project Director may still append its own judgement about a delivered outcome, and the parent reads the script's line as the fact and the Project Director's line as commentary.
For marked replies, the report helper accepts no caller-selected destination and uses the channel resolver for both local and remote homes; its script header owns the exact invocation contract.
The pending-reply guard may restate only the correlated line from a local Project Director's `state/<project-director-id>.status` onto the parent channel, which repairs the common parent-home versus Project Director-home mixup without accepting arbitrary Project Director-home sightings as acknowledgement.
Other correlated Project Director-home status lines remain wrong-home evidence, while a remote home's routed `state/parent-replies.status` is already the parent channel and is not classified as wrong-home.
The Project Director home's own status scans treat that remote channel the same way: `status_scan_parent_channel_exclude` in `bin/fm-classify-lib.sh` resolves the outbound path through the same `bin/fm-parent-channel-lib.sh` binding, and the watcher's signal scan and heartbeat backstop, the away-mode daemon's catch-all scan, and the team-wide folds skip exactly that resolved path, never a file name.
The remote reply adapter already mirrors every channel line into the parent home, so folding the channel again here would only spin spurious wakes and a phantom `parent-replies` task, while a `parent-replies.status` in a main home or in a local Project Director is an ordinary task log that keeps folding and waking.
A missed-reply escalation includes the complete first sighting path and line number in readable shell-escaped form.

## What is deliberately not built

- No mirror of the Project Director's chat: chat can mix outcomes with other conversation, so choosing which sentence is an outcome would itself be model behavior, and every harness exposes turn text differently.
- No threshold escalation of a child's open decision or blocker: a decision the Project Director escalates is a user hold, which is published; a decision the Project Director neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No second watcher or standalone scanner: a lightweight ledger pass runs inside the existing inactive-outcome command on every watcher poll and reuses its receipts and upstream append.
- No orphan lifecycle: teardown refuses instead of removing an undelivered outcome, the same way it refuses on other unlanded conditions.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers the ledger delivery against real ledgers with no harness: immediate done and failed delivery with note, PR, mode, posture, and report pointer, once-only delivery across polls, a Builder `done:` withheld while its named head exists only in the worker copy, a pending one still delivered after teardown removes that copy, a line still being appended, later routine status prose not minting a fresh parent event because the inactive receipt identity binds structured fields only, the remote route, the yield of the inactive path to a terminal ledger, and the real watcher poll driving it.
`tests/fm-captain-hold-lifecycle.test.sh` covers a Project Director home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers teardown delivering a child's final line and refusing when the channel cannot be written.
It also covers the registration-time ready line and its withholding until checks are green under `config/ready-after-green`.
`tests/fm-brief.test.sh` pins the charter's channel rule.
`tests/fm-pending-reply.test.sh` covers helper-selected local routing, remote-channel classification, same-basename restatement before false escalation, readable wrong-home diagnostics, and the rule that arbitrary Project Director-home sightings never acknowledge a reply.
`tests/fm-parent-channel-scan-exclusion.test.sh` covers the home-shape-aware scan exclusion against real remote, main-home, and local-Project-Director fixtures: the watcher signal scan, both heartbeat backstops, the team-wide folds, and the real `fm-wake-drain.sh` end to end.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: real tmux panes, both real watchers re-armed after each wake, and no model, with every delivered parent line and the parent wake it produced.
