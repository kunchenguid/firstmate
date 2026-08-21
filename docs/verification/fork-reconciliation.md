# Fork Reconciliation Plan and Delivery Analysis

This document records the empirical evidence and reconciliation plan for Firstmate's fork repository and delivery path.

## Background and remotes

This Firstmate home operates as a fork where local `main` is authoritative for the fleet.
The repository has three remotes:

- `origin` (`github.com/kunchenguid/firstmate`): upstream repository.
- `fork` (`github.com/BohnBawerick/firstmate`): the captain's fork repository.
- `no-mistakes` (`/home/paiva/.no-mistakes/repos/3437026af8a8.git`): local bare gate repository.

## Evidence measured on 2026-08-19

The commit state measured across remotes and local heads:

- `local main` = `7e09a25`
- `fork/main` = `2114a72`
- `origin/main` = `d843712`
- `git log fork/main..main` = 72 commits
- `git log main..fork/main` = 1 commit (`2114a72`)

Commit `2114a72` is titled `fix(bin): distinguish unreadable away-mode panes from gone ones (#1)`.
It merged PR #1 on `BohnBawerick/firstmate` with `--squash`.
The PR branch was `fm/fm-stale-unreadable-vs-gone` (commit `0a5674532515ed848b5b37b2d8ff30975b157758`).
Because `fork/main` was stale at commit `96876db`, GitHub squashed all 72 missing commits plus the task fix into commit `2114a72`.
Local `main` never received the fix.

## Content verification of commit 2114a72

We evaluated whether the fix in `2114a72` is present in local `main`.

### 1. Patch ID comparison

The patch ID of the underlying task commit `0a56745` was computed using `git patch-id --stable`:

```
8c93cd1f61da926d3e72ef10865ff274184d127c 0a5674532515ed848b5b37b2d8ff30975b157758
```

Searching `git log -p main | git patch-id --stable` for this patch ID produces zero matches.

### 2. Range diff comparison

Running `git range-diff 0a56745~1..0a56745 main~15..main` shows commit `0a56745` has no equivalent commit on `main`.

### 3. Direct file comparison

The 5 files modified by `0a56745` were inspected directly against `local main`:

- `.agents/skills/afk/SKILL.md`: missing the specification that unreadable endpoints are surfaced rather than dropped during away mode.
- `bin/fm-supervise-daemon.sh`: missing `stale_window_recheck`, capture retries, and the gone versus unreadable pane classification.
- `docs/architecture.md`: missing the gone versus unreadable pane architecture note.
- `docs/configuration.md`: missing `FM_STALE_CAPTURE_RETRIES` and `FM_STALE_CAPTURE_RETRY_SLEEP` documentation.
- `tests/fm-daemon.test.sh`: missing the test cases covering gone, unreadable-present, retry-then-ordinary, and dead-is-not-gone behaviors.

### Verdict

The fix in `2114a72` is completely missing in `local main`.

## Minimum safe path to bring the fix into local main

1. A worker creates a branch from current `local main`.
2. Cherry-pick commit `0a56745` from branch `fm/fm-stale-unreadable-vs-gone`.
3. Resolve minor conflicts in `bin/fm-supervise-daemon.sh` and `docs/configuration.md` from intervening commits (`e85be9e`, `416c0d3`).
4. Run `tests/fm-daemon.test.sh` to confirm all tests pass.
5. Fast-forward merge the branch into `local main` using `bin/fm-merge-local.sh`.

## Plan for fork/main

To ensure future PRs have a truthful base:

1. `fork/main` should be reset to match `local main` exactly.
2. What is preserved: all 72 local commits, the full history, and the exact tree running in the fleet.
3. What is lost: the single squash commit `2114a72` on `fork/main` (the underlying commit `0a56745` is preserved in local branch `fm/fm-stale-unreadable-vs-gone` and upstream PR 2587).
4. Force push requirement: YES. Because `fork/main` and `local main` have diverged histories, aligning `fork/main` to `local main` requires `git push --force-with-lease fork main:main`. This is a deliberate operational decision for Firstmate.
5. Consequence: future PRs opened against `fork/main` will have a truthful base, CI will test against the exact fleet codebase, and PR diffs will only show the task's changes.
