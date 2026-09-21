# AXI run-state input captures for v1.75.2

These files own recorded serialized CLI inputs for the `test_captured_v1752_*` case in `../../fm-crew-state.test.sh`.
They were captured on 2026-09-18 with `no-mistakes version v1.75.2 (4debd42) 2026-09-14T06:41:58Z`.
They are replay inputs, not evidence that every composed scenario was driven live.

## Capture provenance

| File | Command and worktree | Observed state |
| --- | --- | --- |
| `overview.toon` | `no-mistakes axi` from a worktree whose branch has no recorded run | Capped `count: 10 of 93 total` window, head fields both quoted and unquoted, beside another branch's active-run block |
| `no-branch-run.toon` | `no-mistakes axi status` from that same worktree | `runs_on_current_branch: 0` with the same capped window |
| `runs.out` | `no-mistakes runs --limit 20` | Coarse ledger listing capped at 20 rows; no row for that worktree's branch |

Every command exited zero, and stdout is unchanged except one substitution: the `repo:` path in `overview.toon` reads `/captured/firstmate`.

## Replay transformations and limits

`seed_v1752_inventory` persists the overview's ten visible rows as the complete inventory and rebinds `repo:` to the disposable repository.
The replayed inventory therefore holds no row for the worktree's branch, reconstructing the branch-without-a-run state that the capped window alone cannot prove.
