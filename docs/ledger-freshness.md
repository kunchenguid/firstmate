# Ledger fact freshness

This note proposes a review convention for time-sensitive operational ledger entries; it does not convert private ledgers into maintained project documentation.

## Proposed markers

An entry that may become false should state its dependency in plain text, for example `Review premise: the upstream fix is still absent from the target branch.` The entry may also use its ledger's existing date field as a review deadline when that field already supports a deadline; do not invent a new date field or reinterpret a creation date as an expiry.

The premise marker records what must be rechecked, not proof that the claim remains true. Before using a ledger fact as a dispatch premise, perform a current check and state in the delivery whether `I reproduced it` or `I did not reproduce it`.

## Searchability limit

A single portable `grep` can find explicitly marked premise-bearing entries, for example:

```sh
grep -nH 'Review premise:' data/backlog.md data/learnings.md data/captain.md
```

It cannot also find every entry missing the marker, nor determine which existing dates are deadlines or whether they have elapsed: grep has no record-boundary awareness for multiline entries, negative matching requires a separately defined inventory of entries, and the existing date fields do not uniformly mean expiry. Therefore this convention does **not** meet the requested one-grep completeness criterion. Do not treat the command above as a complete stale-entry audit. A complete grep-only rule requires first establishing a uniform one-line entry boundary and an existing, semantically explicit deadline field across all relevant ledgers; that prerequisite has not been established here.
