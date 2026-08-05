---
name: research-approved-work
description: >-
  Answer "which reported work was genuinely approved and is still unimplemented?" over this home's scout-report corpus without loading it.
  Use when the captain asks what approved work is outstanding, still owed, or unfinished, when reconciling a recommendation register against reality, and before commissioning work that an earlier investigation may already have covered.
  Read-only: it produces classified evidence, never a change to code, reports, or decision state.
user-invocable: true
metadata:
  internal: true
---

# research-approved-work

This skill answers one recurring question over a corpus too large to read: **which reported work was genuinely approved and remains unimplemented?**

`bin/fm-research-scan.sh` owns every deterministic step and runs with no model involvement.
This file owns the judgement the scanner is not allowed to make.

## Read-only boundary

Producing this answer authorises nothing.
Do not implement anything you find, edit or annotate a report, close or reopen a backlog item, register or resolve a held decision, open or merge a pull request, or change any decision record.
An item classified `approved-unimplemented` is a finding to relay, and commissioning it is a separate captain decision under the ordinary task lifecycle.

## Procedure

**1. Scan first, always.**

```
bin/fm-research-scan.sh
```

If it prints `verdict=no_delta`, the corpus, the durable decision records, and every implementation HEAD are all unchanged since the last run.
**Stop reading here and answer from the previous run's findings.**
Do not open a report, do not re-derive a classification, do not "just check one thing".
That terminal is the entire point of the scanner: reaching it must cost no model turn.

If it prints `verdict=delta`, only the reports on its `changed=` lines need fresh attention.
Every other report's evidence is already cached and unchanged; reopening one is wasted context.

**2. Work from bounded extractions, not reports.**

`bin/fm-research-scan.sh show <report-key>` prints a report's cached projection: headings, recommendation identifiers, and decision-language excerpts.
Open the underlying `report.md` only when a specific classification turns on wording the projection genuinely does not carry, and then read only the section you need.
Run `bin/fm-research-scan.sh schema` when, and only when, you need to parse the index yourself.

**3. Prove approval and implementation separately.**

```
bin/fm-research-scan.sh evidence <identifier> --token <artifact> --token <artifact>
```

Approval and implementation are different questions and neither prover may stand in for the other.
Never conclude "unimplemented" from one absent filename: pass at least two concrete artifacts the work would have created - a config key, a recorded field, a function name, a flag - and the prover refuses an absence verdict below that threshold.
Add `--landing` to check delivery, which is a separate question again.

**The provers locate evidence; they do not grade it, and you must.**
`approval=mentions-found` means a durable record contains the identifier, nothing more - a commission asking an investigation to examine `LC-R4` mentions it exactly as a ruling approving it would.
Read every `approval_hit=` excerpt and decide whether it approves, commissions, cites, or declines.
`implementation=matches-at-head` means a token appeared in a tracked file - `route=` matches a local shell variable as readily as the recorded dispatch field a recommendation asked for.
Open the `impl_match=` paths and confirm the match is the artifact before calling anything implemented.
`landing=no-title-match` searched only a bounded window of pull request titles, so it is never proof that nothing was delivered, and `landing=unavailable-listing-failed` means the forge could not be read at all.

Treating any of these three as a verdict reproduces exactly the false answers this skill exists to prevent.

## Three facts that decide most classifications

**Approval evidence is fragmented, and one source is not durably recorded.**
Approvals in this home live in ruling documents, in backlog task notes, and in direct captain instructions given in chat.
The scanner sweeps the first two.
The third leaves no durable trace at all, so `approval=no-mentions-in-durable-sources` means *the durable sources are silent*, never *this was never approved*.
Treat it as `insufficient-evidence` and ask the captain.

**Delivered is not landed.**
Completed work can sit in an unmerged pull request and be absent from every HEAD.
A verdict built only on the working tree re-commissions finished work, so check delivery before calling anything unimplemented.

**A recommendation is not an approval.**
A numbered register inside a report reads like a work list and authorises nothing.

## Classes

Assign the first class whose evidence is satisfied, in this order.
Every class needs a *graded* excerpt or path, never a bare prover verdict.

| Class | Required evidence |
|---|---|
| `duplicate` | grouped with another item in `duplicates.tsv`; classify the group once |
| `contradicted-by-evidence` | the recommendation rests on a specific claim that current evidence refutes; cite both |
| `superseded` | a later durable record replaces it; cite the successor |
| `implemented-register-stale` | a confirmed artifact at HEAD while the source report still lists it outstanding |
| `approved-blocked` | a ruling or instruction that approves it, no confirmed artifact at HEAD, plus a named blocker: delivery awaiting merge authority, an unmet dependency, or a recorded external wait |
| `partially-implemented` | an approving record, some artifacts confirmed at HEAD and others absent; name which |
| `approved-unimplemented` | an approving record, two or more artifacts absent at HEAD, and no delivery found |
| `proposed-never-approved` | a durable record explicitly declines or rules against it - **never assignable from silence** |
| `insufficient-evidence` | anything else, including every case where only durable-source silence stands against approval, and every case where a match was found but not confirmed |

## Evidence discipline

State the evidence, not your confidence in it.
"Likely unimplemented" and "high confidence" are not findings; "no matches at HEAD across 3 signals in 2 repositories, and no delivery in the searched window" is.
Every classification must cite the approval evidence and the implementation evidence that produced it, separately, and name any source that was silent.
Where a captain instruction conflicts with a report's recommendation, the instruction governs and the conflict is reported, not quietly resolved.

Report what you found and stop.
