# Azure six-profile repeat campaign, 2026-08-27

This directory records the acceptance campaign that starts from public `main` at `7e6d1039acaa421c96d54435ea4f143a050f3736`.
The GitHub API and the clean local checkout independently resolved `refs/heads/main` to that commit before any campaign work began.

The campaign is accepted after two consecutive live rounds.
The operator removed No-Mistakes from this campaign after its task-specific validations became unrelated capacity; Crosscheck was the sole review gate for both rounds.

Round 1 is complete.
Its four direct Relvino scouts returned authored reports and terminal statuses, its secondmate's sole retained child returned the recovered authored report at `bf8f6034db029bf4483184718171b86cb93c9945`, and the parent reconciled that custody in commit `5b128897fb405235bd2ca395bfd1b21bb73efa14` with a verified terminal `idle` summary at outbox sequence 7.
PR #386 received a fresh exact-head Crosscheck CLEAR at `5066a4dde28dba1fca767134e6378c11e4744424` and merged as `c59ef693d95e12108fda0c798234875ff739d035`.
The child was released before its parent, every historical assignment through `asg-00000140` is complete, no historical pending action or tagged ARM resource remains, and the live provider reported zero retained disks.
Unrelated later assignments were explicitly excluded from this scoped cleanup proof.

Round 2 ran from released Firstmate generation `06ad2277f6cf26edbed76b8e90ec4cc9cc4f85ba` and Relvino generation `071a9fb439ea15145d0e7952a59f85d0231d885b`.
Its ten completed Azure assignments exercised `openai-codex` through `openai-codex-6`: direct read-only Relvino scouts used profiles 1, 2, 3, 5, and 6, the secondmate used profile 4, and its sole child used profile 5.
The child's first return omitted the required artifacts, its retained-disk recovery authored the 7,269-byte report but emitted a malformed bare status, and a deterministic status-only recovery produced return commit `01a11717df30da74c9a0d131ebe084c324eb2bd1` with manifest `584be62067460291a7614e85a3ec11e98694f1bdc3e4ef1c1b2227fce9c51fa6` before ordinary child release.
The parent reconciled that custody in commit `9157b957d925729b1ce385eb647c773b5ffad6a1`, emitted terminal `done`, and closed at verified outbox sequence 7 before assignment `asg-00000168` was ordinarily released.
Concurrent Crosscheck returned CLEAR for PR #402 at exact head `85dbb69ed5ce4cb849d8ef8ea0eb188eb6a1c811` in 185.186 seconds, including 106.717 seconds of reviewer time, with declared cost `$0.08406146`.
Azure recorded `$259.048977863457` at the Round 2 baseline and `$262.659573226489` at final cleanup, a `$3.610595363032` observed increase.
Every `az6r2` queue record is complete; no campaign worker, pending provider action, tagged ARM resource, or retained disk remains.
One unrelated queued validation record remained with zero actual workers and was explicitly outside the campaign cleanup scope.

`docs/azure-requirements.md` remains the acceptance authority except for the operator's explicit campaign-local removal of No-Mistakes described above.
