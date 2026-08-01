# Stalled lane recovery - 2026-08-01

This report records the pre-mutation inventory and terminal disposition of five lanes stranded by the fleet incident.
The inventory below was written before any recovery mutation.

## Initial inventory

### `fm/ci-shard-behavior-tests-ci-m9`

- Uncommitted: six real-work paths in the lane worktree.
  The changes replace `tests/fm-teardown.test.sh` with two three-line wrappers and a shared `tests/fm-teardown-suite.sh`, update the behavior duration inventory from 84 to 85 scripts, and add a partition-completeness assertion covering all 106 normal-run teardown cases plus the three focused-only cases.
- Committed but unpushed: none.
  Local `7057251` exactly matches `origin/fm/ci-shard-behavior-tests-ci-m9`.
- Remote: `origin/fm/ci-shard-behavior-tests-ci-m9` at `7057251`.
- Review: PR 56 is open from that exact branch and head, with 12 checks passing and 3 failing before recovery.

### `fm/fm-account-rescue-a2`

- Uncommitted: none.
- Committed but unpushed: none.
  Local `0383c2c` exactly matches `origin/fm/fm-account-rescue-a2`.
- Remote: `origin/fm/fm-account-rescue-a2` at `0383c2c`.
- Review: contrary to the stale incident table, PR 27 is already open from that exact branch and head.
  It had 4 checks passing and 1 failing before recovery.

### `fm/fm-main-green-g7`

- Uncommitted: seven staged scratch paths.
  The staged patch reverses the lane's completed safety work by removing symlink refusal, nested repository locking, registered-child worktree attribution, specific structural error ordering, endpoint-before-child proofing, scoped tmux fixture evidence, and related documentation and test hardening.
  This is rollback scratch, not publishable work, and is deliberately named here before removal.
- Committed but unpushed: none.
  Local `923164a` is an ancestor of `origin/fm/fm-main-green-g7`; the remote is seven commits ahead at `25890a6`.
- Remote: `origin/fm/fm-main-green-g7` at `25890a6` and an older divergent gate ref at `no-mistakes/fm/fm-main-green-g7`.
- Review: no pull request exists for `fm/fm-main-green-g7`.

### `fm/ci-baseline-fixes-s2`

- Uncommitted: none.
- Committed but unpushed: three commits exist only locally at inventory time.
  They adjust the abandoned metadata-lock timing fixture, document the exact no-mistakes PR marker, and add no-mistakes-required policy coverage.
- Remote: no branch exists on `origin` at inventory time.
- Review: no pull request exists for this branch.
  PR 55 is separate work from `fm/precompact-stow-bridge-s2` and does not carry these commits.

### `rules-rebase-after-51`

- Uncommitted: none in the detached lane.
- Committed but unpushed: none from the lane's intended work.
- Remote: completed head `ddc62f3` is pushed as `origin/fm/crystallize-rules-c4`.
  The local bookkeeping ref `fm/rules-rebase-after-51` remains at the earlier PR 51 merge commit and carries no additional lane work.
- Review: PR 52 is open from `fm/crystallize-rules-c4` at exact head `ddc62f3`, so the lane's work is already in review and the detached recovery lane should not be revived.

## Recovery results

### `fm/ci-baseline-fixes-s2` - in review

Pushed the three disk-only commits to `origin/fm/ci-baseline-fixes-s2` before any other recovery mutation.
Opened PR 60, `test: preserve stranded CI baseline fixes`, for GitHub CI verification.
The worktree is clean and tracks the new remote branch.

### `fm/ci-shard-behavior-tests-ci-m9` - in review

Preserved all six real-work paths in commit `f7d16e2`, `ci: split teardown behavior suite across shards`, and pushed it without rewriting the branch.
The commit turns the former monolithic test into a shared non-executable suite plus two executable partition wrappers, updates the measured weights, and proves complete assignment in the shard behavior test.
Static verification used `git diff --check` and `bash -n` on the changed shell tests.
The worktree is clean and PR 56 now points at `f7d16e2`.
The full suite was deliberately not run because it can reach the live fleet; GitHub CI is the requested runtime verification path.

### `fm/fm-account-rescue-a2` - in review

No recovery mutation was needed.
The branch and worktree are clean, `origin/fm/fm-account-rescue-a2` exactly carries local head `0383c2c`, and PR 27 is already open from that exact head.
The incident table's "no PR" statement was stale, so no duplicate pull request was created.

### `fm/fm-main-green-g7` - in review

Removed the seven-file staged rollback only after the initial inventory named it as scratch and explained the completed safety work it reversed.
No committed work was removed, no stash was touched, and no branch history was rewritten.
The lane worktree is clean.
Opened PR 61, `fix: preserve stranded teardown safety repairs`, from the existing remote head `25890a6`.
The pull request reports a merge conflict with current `main`; recovery deliberately left it in review without rebasing or force-pushing the gate-tracked history.

### `rules-rebase-after-51` - deliberately closed

Confirmed through the GitHub pull-request head that the lane's completed `ddc62f3` head is already carried exactly by open PR 52 from `fm/crystallize-rules-c4`.
The detached recovery checkout is clean, and the stale local bookkeeping ref contains no extra work beyond the already landed PR 51 history.
The lane was therefore deliberately closed without reviving, rebasing, deleting, or opening a duplicate pull request.

## Verification and deliberate omissions

All four named branch worktrees are clean after recovery, and the fifth detached lane was already clean.
GitHub confirms exact open pull-request heads for PRs 27, 52, 56, 60, and 61.
PR 60 started its GitHub checks; its policy check rejects the intentionally direct recovery PR while the runtime jobs remain the requested verification path.
PRs 56 and 61 reported no checks configured immediately after their recovered heads entered review, so this report does not claim they are green.

No full local suite was run because it can reach real terminal sessions in the live fleet.
No pull request was merged.
No branch was force-pushed, rebased, reset, or otherwise rewritten.
No stash was dropped.
No committed work was discarded.
