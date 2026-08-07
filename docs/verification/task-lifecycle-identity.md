# Task lifecycle identity verification

This record holds current executable evidence for worktree custody and immutable delivery-revision binding.
[`../architecture.md`](../architecture.md#worktrees-not-branches-in-your-checkout) owns the stable design and mechanism boundaries.
Script headers and `--help` own exact command mechanics.

## Environment

The evidence was refreshed on 2026-08-07 with:

```text
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
git version 2.43.0
node v22.23.1
gh version 2.96.0 (2026-07-02)
```

## Custody and recovery

The public `fm-spawn.sh` regression uses real linked Git worktrees behind a fake terminal provider.
It proves physical-path settling, a conflicting task owner refusal, malformed stale-record refusal, safe pooled reuse only after record removal, and same-task recovery in the exact recorded copy without another Treehouse allocation.

```text
$ tests/fm-spawn-worktree-settle.test.sh
ok - a single transient stale pane_current_path read is not accepted as the worktree
ok - an already-settled pane confirms via the existing inter-poll sleep, not an extra full cycle
ok - spawn refuses a second task record for one isolated copy
ok - spawn refuses pooled reuse while an old custody identity is malformed
ok - a pooled copy is reusable only after its prior authoritative record is gone
ok - safe same-task recovery reuses the exact recorded isolated copy
# all fm-spawn-worktree-settle tests passed
```

The shared check runs after allocation for tmux, Herdr, Zellij, Orca, and cmux because all five converge on `fm-spawn.sh` before metadata publication.
The same-task automatic recovery axis is intentionally narrower: tmux and Herdr expose recovery-grade agent-process state, while Zellij, Orca, and cmux return an inconclusive verdict and the public spawn refuses rather than duplicating a process.
The Orca regression additionally proves malformed existing identity refuses before an Orca worktree is allocated.

## Immutable review and merge revisions

The local-only public interface proves that approval cannot be inferred from branch name, a moved revision refuses, a fresh preparation replaces the binding, the merge lands the immutable object, dirty work never becomes ready, and duplicate custody blocks readiness.

```text
$ tests/fm-merge-local.test.sh
ok - local merge refuses absent revision identity
ok - local rebase or fix requires a fresh binding and then lands only that commit
ok - local readiness refuses uncommitted work
ok - delivery refuses a second task record on the same isolated copy
```

The GitHub merge wrapper regression proves canonical repository derivation, mandatory pre-existing readiness, exact current-head verification, red-check refusal, and atomic `--match-head-commit` delivery.

```text
$ tests/fm-pr-merge.test.sh 2>/dev/null | grep -E 'head movement|red or pending|parses a GitHub'
ok - fm-pr-merge refuses GitHub head movement without silently rebinding approval
ok - fm-pr-merge refuses red or pending work before the atomic merge
ok - fm-pr-merge parses a GitHub PR URL into gh-axi number and --repo arguments
```

The review regression proves exact PR and local diffs, moved-head refusals, and refusal when immutable identity is absent.

```text
$ tests/fm-review-diff.test.sh 2>/dev/null
ok - review diff uses the exact registered PR revision
ok - review diff refuses a PR head that moved after readiness registration
ok - review diff refuses absent revision identity
ok - review diff uses the exact prepared local revision
ok - review diff refuses a local branch that moved after preparation
```

GitHub and GitLab poll registration, crash recovery, replacement protection, moved-head diagnostics, and explicit fresh rebinding remain in the security suite.

```text
$ tests/fm-pr-check-security.test.sh 2>/dev/null | grep -E 'fresh revision binding|GitLab merge requests|exact merged results'
ok - GitLab merge requests are followed on any instance and never wake falsely
ok - GitHub and GitLab exact merged results share one retirement path
ok - an intentional PR update requires and receives one explicit fresh revision binding
```
