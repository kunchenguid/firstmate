# Worker push-safety verification

Audience: maintainer verification.

This record supports the worker push guard in `bin/fm-push-guard.sh` and the
generated instructions in `bin/fm-brief.sh`. The behavior tests remain in
`tests/fm-push-guard.test.sh` and `tests/fm-brief.test.sh`.

## Independent Git-topology proof

Verified independently by Firstmate on 2026-08-04 in a scratch repository.
The guard was invoked against five real local/remote histories rather than a
mocked Git command:

| Topology | Exit | Observed guard result |
| --- | ---: | --- |
| Local branch dropped a remote review commit | 1 | `refusing push to origin/feat; local HEAD would lose these remote commits` and the lost row named `05dd88ec review fix that must not be lost` |
| Ordinary clean descendant | 0 | `origin/feat is an ancestor of local HEAD` |
| Content-preserving rebase with changed commit identity | 0 | `all 1 remote-only commit(s) have patch-equivalent local replacements` |
| Current branch has no upstream | 1 | Refused and instructed the caller to name the remote and branch explicitly |
| Configured remote is unreachable | 1 | `cannot determine remote head; refusing the push`; the unreachable ref was not treated as an absent branch |

The first construction of the content-preserving-rebase case produced a false
refusal because its fixture had not actually reproduced the remote patch.
After repairing that fixture, the genuine patch-equivalent history passed. This
counterfactual confirms that the pass depends on reproduced patch content, not
on merely presenting a rebuilt history.

## Regression baseline

The focused guard, brief, test-runner, lint, and documentation checks passed on
the feature branch. A broader run reported eight failures, so the same eight
test scripts were run from a clean detached worktree at
`origin/main` (`4ee4a0a2790cfaa5e47b30fa462f16546f2ab5b6`). Seven failed there:

```text
tests/fm-backend-orca.test.sh
not ok - Orca spawn should fail when metadata cannot be written

tests/fm-busy-adapter-wiring.test.sh
not ok - turn_end drive failed: node:internal/modules/esm/get_format:189
TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension ".ts"

tests/fm-calm-pi-extension.test.sh
not ok - Pi calm missing-adapter-export path failed: node:internal/modules/esm/get_format:189
TypeError [ERR_UNKNOWN_FILE_EXTENSION]: Unknown file extension ".ts"

tests/fm-pi-watch-extension.test.sh
not ok - Pi extension must surface an external healthy watcher as an owned-wake failure: expected exit 0, got 1

tests/fm-session-start.test.sh
tests/fm-session-start.test.sh: line 732: BASHPID: unbound variable
not ok - concurrent session-lock acquisition produced 0 winners

tests/fm-teardown.test.sh
not ok - herdr-preflight-missing-adapter: the retryable pre-return refusal was not explained visibly

tests/fm-turnend-guard.test.sh
not ok - Pi guard must inject once for no-tool and multi-tool logical runs: expected exit 0, got 1
```

`tests/fm-backend-herdr-presentation-e2e.test.sh` was the eighth failure in the
feature-branch suite, but it passed when run on `origin/main` and passed again
when isolated on the feature branch:

```text
origin/main: exit=0 duration_ms=283483
feature branch: exit=0 duration_ms=291183
```

It is therefore recorded as non-reproducible shared-runtime behavior, neither
as a proven pre-existing failure nor as a reproducible branch regression.
