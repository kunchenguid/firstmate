# Known no-mistakes defects

Recorded 2026-08-29 from two incidents reported the same night, both against no-mistakes v1.45.4 (0c58eb7, 2026-08-04T23:05:34Z), `gh` 2.46.0, `gh-axi` 0.1.24.
no-mistakes is an external tool; these are known defects to work around, not something firstmate repairs.
[`AGENTS.md`](../AGENTS.md) section 7 "Validate" points here.

## CI-polling blindness

The pipeline's own `ci` step repeated the identical warning line for 14+ minutes on PR #111 while the underlying check was already green:

```text
warning: could not check CI: gh pr checks: exit status 1
```

At the same moment, both of the following succeeded by hand, confirming the checks were actually green and the pipeline's own polling was the only thing that could not see it:

```sh
gh pr checks 111
gh-axi pr checks 111
```

The crew sat blocked on already-green work for the full 14+ minutes with no distinguishing signal between "still running" and "polling is broken."

Workaround: when a task's `ci` step repeats the same `could not check CI` warning for more than a couple of minutes, firstmate verifies the PR's checks directly (`gh pr checks <n>` or `gh-axi pr checks <n>`) and releases the crew once they are confirmed green, rather than waiting on the pipeline's own polling to resolve.

## Custody deadlock

On branch `fm/dl-whatsapp-cloud-api`, run `01M11RPKD57X1P3CE09XXWHBRK` ended cancelled with its gate ref stuck at one commit while its recorded preserved pipeline head was a different commit.

```sh
no-mistakes axi sync --recover
no-mistakes axi sync --recover --keep-local
```

Both refused identically (the exact refusal text was not preserved by the reporting crew; both invocations were confirmed inert - no refs or files were changed by either).

```sh
no-mistakes axi run
```

then refused to start because the previous run's branch custody had not been recovered - a closed loop: recovery refuses, and running without recovery also refuses, with no documented exit from either `axi sync --help` or `axi run --help` at this version.

Workaround: push the verified branch directly with plain `git push` and update the existing PR in place, skipping `no-mistakes axi run` for that landing.
The repo's own merged pre-push gate (`npm run ci`) already ran clean on that branch, so the direct push is not shipping unverified work - it is bypassing only the stuck custody bookkeeping, not the verification itself.

## Related, not a no-mistakes defect

[`bin/fm-verify-page.sh`](../bin/fm-verify-page.sh) replaced `chrome-devtools-axi` in firstmate's documented browser-verification workflow after `chrome-devtools-axi` reported success (`screenshot: /tmp/shot.png`) while writing no file; see that script's header and `tests/fm-verify-page.test.sh` for the replacement's own contract and evidence.
`chrome-devtools-axi` itself is unmodified and still usable by hand.
