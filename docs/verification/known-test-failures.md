# Known pre-existing test failures

Audience: maintainer verification.

This record supports the guarantee that a fresh `bin/fm-test-run.sh --all` run on `main` is expected to be clean apart from the entries below, so a contributor can tell their own branch's failures apart from these without re-deriving the triage.
Every entry here was independently reproduced on a fresh, unmodified `origin/main` checkout, so none of them are caused by any branch.
When an entry's underlying cause is fixed, or when CI's environment changes so it stops reproducing there, remove the entry and close its linked issue.

## Environment gaps with no risk to CI

`tests/fm-lint-workflows.test.sh` and `tests/fm-lint.test.sh` self-skip the actionlint-dependent cases when the pinned actionlint is absent from `PATH`, exactly like the existing ShellCheck `pinned_ready` guard.
CI always installs the pin first, so this affects local runs only.
Install the pin with `bin/fm-install-actionlint.sh` to get full local coverage.

## Version drift against installed tool binaries

Two real end-to-end tests exercise the actual installed `herdr` binary, and one exercises the actual installed `pi` binary, rather than a stub.
On this class of test, when the installed version moves past what the mitigation or extension was verified against, the test can fail even though nothing in this repo changed.

| Test | Verified against | Reproduces with | Issue |
| --- | --- | --- | --- |
| `tests/fm-backend-herdr-focus-flash-e2e.test.sh` | herdr 0.7.5 / 0.8.0 floor | herdr 0.8.2 | [#2841](https://github.com/kunchenguid/firstmate/issues/2841) |
| `tests/fm-backend-herdr-presentation-e2e.test.sh` | herdr 0.7.5 / 0.8.0 floor | herdr 0.8.2 | [#2841](https://github.com/kunchenguid/firstmate/issues/2841) |
| `tests/fm-calm-pi-extension.test.sh` (`exact_watcher` case) | Pi 0.81.1 / 0.82.0 | Pi 0.84.2 | [#2842](https://github.com/kunchenguid/firstmate/issues/2842) |

## Real, unresolved code-path discrepancy

`tests/fm-on.test.sh` fails on a mismatch between the sorted PATH order its portable-PATH contract test reconstructs from a literal glob, and the (apparently unsorted) order `bin/fm-on.sh`'s real remote-dispatch path actually produces through its fake-ssh harness.
This is not version drift or an environment quirk: `bin/fm-remote-job-lib.sh`'s own glob helper (`fm_remote_job_append_glob_dirs`, via `compgen -G`) produces the correctly sorted order when called directly, so the discrepancy is somewhere in the call chain the test actually drives.
See [#2843](https://github.com/kunchenguid/firstmate/issues/2843) for what was measured and what still needs tracing.

## Load-sensitive flake

`tests/fm-watcher-lock.test.sh` passes cleanly every time it is run in isolation - confirmed repeatedly, on both a fresh `origin/main` checkout and a feature branch - but has been observed to fail specifically when the full suite runs under concurrent load.
Do not widen `bin/fm-test-run.sh --jobs` beyond its current use until this is understood; see [#2844](https://github.com/kunchenguid/firstmate/issues/2844) for what was measured.

## Verification record

Measured 2026-08-23 on macOS 26.5.2 arm64, herdr 0.8.2, Pi 0.84.2, with the following commands and exit codes.

```sh
bash bin/fm-test-run.sh tests/fm-backend-herdr-focus-flash-e2e.test.sh tests/fm-backend-herdr-presentation-e2e.test.sh
bash bin/fm-test-run.sh tests/fm-calm-pi-extension.test.sh
bash bin/fm-test-run.sh tests/fm-on.test.sh
bash bin/fm-test-run.sh tests/fm-watcher-lock.test.sh   # isolated: passes; full-suite: intermittently fails
```

Each of the first three failed identically whether run against a fresh `origin/main` checkout or a feature branch with zero file overlap with the failing test.
`tests/fm-watcher-lock.test.sh` passed in isolation on both trees, twice each.
