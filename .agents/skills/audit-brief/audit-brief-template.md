# Audit brief template

This file is the single owner of the audit-brief contract: every field, expansion trigger, budget rule, carry-forward rule, stop condition, and report requirement below is stated here once.
Fill every bracketed field per task when writing an audit brief or the instructions an audit worker follows, and drop a guidance line only when its section genuinely does not apply, saying why in the brief.
`bin/fm-chatgpt-consult.sh` injects this same file into its audit-stage instructions, so a ChatGPT-generated audit prompt is structured by it without a second copy of the contract.

## Audit objective
[One sentence: what is being audited, and the confidence required before the area may be called clean.]

## Threat model or defect class
[What could be wrong here, and what "clean" means for this audit.]

## Entry points and initial scope - this list is never a whitelist
- Files and slices: [path plus symbol or line range]
- Navigation maps and indexes already available: [path, or "none" - building new maps is later work and is not part of this brief]
- Invariants to verify: [each with the place where it is defined]
- Dependencies to establish: [callers, consumers, configuration, shared state]

The list chooses where reading starts; it never bounds where evidence may be followed.
Every credible lead may be followed anywhere in the repository, and each expansion is logged in the report rather than requested in advance.

## Bounded initial reconnaissance
This first phase confirms or falsifies the stated scope by reading maps, indexes, interfaces, and section headers instead of full bodies.
A context that names no files, symbols, or line ranges starts here and establishes exact initial scope before deep inspection begins.

## Reading budget - effort guidance, never a hard limit
- Reconnaissance: [e.g. about 15% of effort] as described above.
- Targeted inspection: [the bulk of effort] - the slices above plus their dependency closure.
- Expansion: unbounded whenever trigger evidence appears; record each expansion and the reason it was needed.

A budget shapes effort, never verdicts: following credible defect evidence past the budget is the job done correctly, not a rule broken.

## Expansion triggers - any one of these requires broader inspection
- A finding depends on behavior outside the initial scope.
- A relevant invariant is defined elsewhere.
- Callers, consumers, configuration, or shared state affect the result.
- Evidence conflicts across files or documents.
- A required security, validation, locking, or integrity check cannot be located.
- An assumption about external behavior cannot be verified with a cited line.

## Verification required
[Per finding: the reproduction, test, or trace that establishes the verdict, plus the surrounding assumption confirmed with a cited line.
No finding is reported from an excerpt alone.]

## Carry-forward discipline
- Every later turn and status update carries current conclusions, unresolved questions, file:line citations, and the next investigation steps - not the accumulated history.
- Raw evidence stays in files and logs; refer to it by path instead of pasting it.
- Paste only the excerpts a current decision needs.
- Complete source files, verbose tool outputs, prior reports, the brief itself, and unchanged background are never re-pasted.
- Every observation needed to reproduce or challenge a finding is preserved: this reduces retransmission, never the evidence.

## Stop conditions
Stop only when the required verification is complete, the defect-class checklist is exhausted, and every expansion trigger is resolved with cited lines or explicitly recorded as unresolved.
"Looks clean here" is never a stop while a trigger is open.
Fewer findings are not a win: judge the result by missed defects, never by tokens saved.

## Report requirements
- Findings with file:line evidence.
- A scope-expansion log: what was added beyond the initial scope, why, and what it showed.
- A "scope sufficient" statement backed by evidence, together with unresolved investigation leads or an explicit "none".
