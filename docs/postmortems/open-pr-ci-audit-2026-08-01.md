# Open pull request CI audit, 2026-08-01

## Finding

The task framing told the captain that 16 red pull requests likely shared one cause.
This audit corrects that framing: the dashboard is stale multi-cause history, not one shared failure.
The pull requests share a stale presentation because most checks were recorded against older `main` snapshots and did not rerun after the underlying failures were repaired on `main`.
The actual logs contain several independent signatures.
The missing four pull requests from the original abbreviated list are #30, #28, #27, and #26.

## Check clusters

| Failing check | Pull requests | Count | Backlog classification |
| --- | --- | ---: | --- |
| Behavior tests | #50, #48, #47, #46, #45, #44, #43, #42, #38, #33, #30, #28, #27, #26 | 14 | 13 stale-base failures and 1 real branch defect |
| PR must be raised via no-mistakes | #56, #55, #50, #47, #30 | 5 pull requests and 6 failed check runs because #56 has two runs on the same head | Real policy violations that require republishing through no-mistakes |
| Lint shell scripts | #56, #30 | 2 | Real branch defects |

The no-mistakes failures all have the exact signature `This PR was not raised through no-mistakes.`
They are policy failures caused by the missing deterministic pipeline marker in the pull request body, not test failures.
The #56 lint failure is four `SC1091` findings in the new split-suite wrappers.
The #30 lint failure is a separate group of ShellCheck findings in that branch.

## Behavior signature clusters

| Signature | Pull requests | Count | Backlog classification |
| --- | --- | ---: | --- |
| `seed failed` after `refusing explicit secondmate home whose default branch cannot be refreshed safely` | #50, #48, #44 | 3 | Stale base needing rebase |
| `capability refusal omitted the offending secondmate` | #45, #43, #38 | 3 | Stale base needing rebase |
| `teardown failed for the empty secondmate home` | #47, #27 | 2 | Stale base needing rebase |
| Browser cleanup integration retried removal of an already-absent task temp root | #46 | 1 | Real defect in the pull request branch |
| Backend behavior file returned nonzero after its printed assertions passed | #42 | 1 | Stale base needing rebase |
| Occupied release-drifted Herdr server assertion | #33 | 1 | Stale base needing rebase; the historical real defect is fixed on `main` |
| Successful direct rollback left task metadata | #30 | 1 | Stale base needing rebase; the historical real defect is fixed on `main` |
| Failed direct spawn did not return its worktree | #28 | 1 | Stale base needing rebase; the historical real defect is fixed on `main` |
| Upgraded brief omitted completion-report sections | #26 | 1 | Stale base needing rebase |

No genuinely flaky check was found, so the flaky classification count is zero.

The eight failures in the first three rows form the largest root-cause family.
They came from secondmate fixtures and teardown assumptions that had drifted from the hardened default-branch, home-layout, and diagnostic contracts.
They were not timing failures and did not depend on a live terminal backend.

Commit `717eedb` repaired the capability assertion by checking the canonical offending home path and the actual capability-gate diagnostic.
Commit `5bec56b` repaired the lifecycle fixture by giving it an isolated default-branch source repository and repaired teardown to resolve projects from the secondmate home.
That same commit carried the related secondmate fixture repairs that the fail-fast behavior loop had not reached.
Five remaining behavior signatures were separate historical regressions or stale fixtures, including the Herdr correction in `18f29ab`, failed-spawn cleanup in `3e597f4`, and report-heading assertion correction in `c3cb1b6`.
The #46 failure is branch-specific: its browser reap path reaches `safe_remove_task_tmp` after the retry fixture's task temp root is already absent.

## Proof that load contention is not the dominant cause

None of the 14 failed Behavior logs ended in a shared timeout, exhausted descriptor, shared socket, or occupied live-fleet signature.
They ended at the assertions and fixtures listed above.
The latest four `main` CI runs are all green at current `main` commit `f1cafce`:

- [Run 30687947393](https://github.com/ruby-dlee/firstmate/actions/runs/30687947393)
- [Run 30686681007](https://github.com/ruby-dlee/firstmate/actions/runs/30686681007)
- [Run 30657355610](https://github.com/ruby-dlee/firstmate/actions/runs/30657355610)
- [Run 30648119449](https://github.com/ruby-dlee/firstmate/actions/runs/30648119449)

Every red pull request still records a base snapshot older than `f1cafce`, ranging from `8a92a35` through `d7db2dc`.
The dashboard therefore reports historical failures even though the repaired base has passed the complete CI workflow four consecutive times.

## Remediation

No new shared production fix is justified by these logs because the dominant secondmate root-cause family and the other inherited Behavior failures are already fixed on `main`.
Rebasing or otherwise refreshing the 13 inherited Behavior-red pull requests onto current `main` should clear that check.
The following 10 pull requests have no other failing check and should become fully green after that refresh: #48, #45, #44, #43, #42, #38, #33, #28, #27, and #26.
Pull requests #50, #47, and #30 should clear Behavior after a refresh but will remain red on the no-mistakes policy check, and #30 also retains its branch-specific lint failure.
Pull request #46 needs its branch-specific browser cleanup ordering fixed before its Behavior check can be expected to pass.
Pull requests #55 and #56 will not be fixed by a rebase because their failures are unrelated to the inherited Behavior history.
Pull requests #30, #47, #50, #55, and #56 must be republished through the no-mistakes pipeline rather than weakening the policy check.
Pull requests #30 and #56 also need their own lint findings fixed.

No local behavior suite was run for this audit because a live fleet was present.
All failure evidence came from GitHub Actions logs, and current-base health came from isolated GitHub Actions runs.
