# Azure six-profile repeat campaign, 2026-08-27

This directory records the acceptance campaign that starts from public `main` at `7e6d1039acaa421c96d54435ea4f143a050f3736`.
The GitHub API and the clean local checkout independently resolved `refs/heads/main` to that commit before any campaign work began.

The campaign is not yet accepted because Round 2 is still running.
The operator removed No-Mistakes from this campaign after its task-specific validations became unrelated capacity; Crosscheck is the sole review gate for both rounds.

Round 1 is complete.
Its four direct Relvino scouts returned authored reports and terminal statuses, its secondmate's sole retained child returned the recovered authored report at `bf8f6034db029bf4483184718171b86cb93c9945`, and the parent reconciled that custody in commit `5b128897fb405235bd2ca395bfd1b21bb73efa14` with a verified terminal `idle` summary at outbox sequence 7.
PR #386 received a fresh exact-head Crosscheck CLEAR at `5066a4dde28dba1fca767134e6378c11e4744424` and merged as `c59ef693d95e12108fda0c798234875ff739d035`.
The child was released before its parent, every historical assignment through `asg-00000140` is complete, no historical pending action or tagged ARM resource remains, and the live provider reported zero retained disks.
Unrelated later assignments were explicitly excluded from this scoped cleanup proof.

Round 2 launched from released Firstmate generation `06ad2277f6cf26edbed76b8e90ec4cc9cc4f85ba` and Relvino generation `071a9fb439ea15145d0e7952a59f85d0231d885b`.
Its assigned top-level placements are `openai-codex` (web), `openai-codex-2` (tests), `openai-codex-3` (API), `openai-codex-4` (secondmate), and `openai-codex-5` (jobs); the marked sole-child request owns the remaining `openai-codex-6` profile requirement.
Round 2 still needs its exact-head Crosscheck, all authored returns, child-before-parent release, spend/timing record, and scoped zero-resource proof before this record can claim two consecutive successful rounds.

`docs/azure-requirements.md` remains the acceptance authority except for the operator's explicit campaign-local removal of No-Mistakes described above.
