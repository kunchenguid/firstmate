# AXI run-state input captures for v1.75.2

These files own recorded serialized CLI inputs for the `test_captured_v1752_*` cases in `../../fm-crew-state.test.sh`.
They were captured on 2026-09-18 with `no-mistakes version v1.75.2 (4debd42) 2026-09-14T06:41:58Z`.
They are replay inputs, not evidence that every composed scenario was driven live.

## Capture provenance

| File | Command and worktree | Observed state |
| --- | --- | --- |
| `overview.toon` | `no-mistakes axi` from a worktree whose branch has no recorded run | Capped `count: 10 of 93 total` window, head fields both quoted and unquoted, beside another branch's active-run block |
| `no-branch-run.toon` | `no-mistakes axi status` from that same worktree | `runs_on_current_branch: 0` with the same capped window |
| `stacked-ci.toon` | `no-mistakes axi status --run 01M2SS4ZQEBBP3ZAV5WBZ5X4Z5` from its own worktree | Live ci step on a branch stacked on another unmerged branch, with the `branch_sync.pipeline.submitted_head` record |
| `runs.out` | `no-mistakes runs --limit 20` | Coarse ledger listing; the stacked branch has a single row |

Every command exited zero, and stdout is unchanged except two substitutions: the `repo:` path in `overview.toon` reads `/captured/firstmate`, and the fork URL in `stacked-ci.toon` reads `captured-fork`.

## Replay transformations and limits

`seed_v1752_inventory` persists the overview's ten visible rows as the complete inventory and rebinds `repo:` to the disposable repository.
`captured_v1752_stacked_status` rebinds only `submitted_head`, the `local` head, and optionally the pipeline run id; the run's own head stays the captured commit, which the disposable repository never has.
The stacked capture was taken after its worker had synced to the pipeline's rewritten head, so its `branch_sync.state` is `dirty`; the earlier moment when the worktree still sat at the submitted head was observed only through its reported symptom, and the replay reconstructs it.
