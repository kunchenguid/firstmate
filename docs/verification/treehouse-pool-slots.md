# Treehouse pool slot verification

Audience: maintainer verification.

This record supports the guarantee owned by the [`bin/fm-spawn.sh` header](../../bin/fm-spawn.sh) that no two workers are ever given the same working copy, and the two pool exit codes it reports.
It records only the facts about the external `treehouse` binary that the guard depends on, so they can be re-established when that tool changes.
Incident chronology and the branch's own evidence stay in the private task report.

Portable regressions: [`../../tests/fm-spawn-pool-slot-occupancy.test.sh`](../../tests/fm-spawn-pool-slot-occupancy.test.sh) for allocation, and the two reassigned-slot cases in [`../../tests/fm-control-relaunch.test.sh`](../../tests/fm-control-relaunch.test.sh) for relaunch.
Both drive the real spawn path against a pool stub, so the facts below are what pins that stub to the real tool.

## What the allocator already guarantees

Verified 2026-09-25 against `treehouse v2.3.0` on Linux, in a throwaway repository whose `treehouse.toml` set `max_trees = 1` and a private pool root.

- A slot holding a running process is reported `in-use`, and at exhaustion `treehouse get` refuses rather than reissuing it.
  With a `sleep` process whose working directory was the slot, both `treehouse get --lease` and the interactive `treehouse get` printed `all 1 worktrees are in use or dirty (max_trees = 1). Run 'treehouse status' to see details, or increase max_trees in treehouse.toml` and handed out nothing.
- A leased slot is refused the same way, and the refusal is also what a blocked slot creation produces: with `max_trees = 3`, the only slot in use, and a plain file planted where the next slot directory would go, `treehouse get` refused with `mkdir .../2: not a directory` rather than falling back to the occupied slot.
- A slot with no process in it and a clean tree is reported `available` and IS handed out at exhaustion.
  That is the whole gap Firstmate's guard closes: the slot is free by the allocator's definition and still held by a Firstmate task.

So the allocator's stale detection and its exhaustion behavior are sound, and neither needed changing; the missing check was Firstmate's own, and no defect was reported upstream.

## The two readings the guard depends on

- `treehouse status --json` prints an array of `{name, path, status, flavor, lease_id, lease_holder, leased_at, processes}`, where `status` is one of `available`, `in-use`, or `leased`, and `processes` is an array of `{pid, name}` for the processes whose working directory is inside the slot.
  `path` is absolute and physical, which is what lets a caller match it against a resolved worktree.
  `bin/fm-wake-lib.sh`'s `fm_treehouse_slot_pids` and `fm_treehouse_pool_has_free_slot` read exactly those two fields, through `jq` (verified with `jq-1.8.1`).
- The pool's size limit is the top-level `max_trees` of the repository's `treehouse.toml`, and `16` when that file is absent: `treehouse init` writes `max_trees = 16`, and with no `treehouse.toml` the seventeenth `treehouse get --lease` refused with `all 16 worktrees are in use or dirty (max_trees = 16)`.
  `fm_treehouse_pool_at_limit` compares the slot count against it, because nothing `available` is not exhaustion on its own: the slot Treehouse just created reads `in-use` once the caller's shell is in it.
- Occupancy is a working-directory scan, not a lease: `treehouse status --json` reported the stray `sleep` as `{"pid":88539,"name":"sleep"}` while `lease_id` stayed empty.
  A crewmate slot therefore carries no record of WHICH task owns it, which is why Firstmate keeps its own `.fm-slot-owner` claim beside the checkout.

## Why homes share one pool

Verified 2026-09-25 on this machine.
The pool root is content-addressed per repository, so every home working on one project shares one pool: the `handyservices-app` pool held slots claimed by three different homes at once (the main home and two secondmate homes seeded into worktrees of the firstmate repo).
All three resolve to the same local root home through `fm_firstmate_root_home`, so they also share the one project lock that serializes allocation and return.
