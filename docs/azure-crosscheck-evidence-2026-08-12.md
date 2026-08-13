# Azure Crosscheck implementation evidence - 2026-08-12

## Scope

This evidence covers the pre-deployment implementation checkpoint for the Azure Crosscheck adapter after integration with the released private-controller Azure runner.
It does not claim a live Azure review, policy-grade acceptance, or cloud-default readiness.
Azure mutation remained prohibited because the released foundation is only partially deployed with zero VMs and has not been reported safe for reconciliation.

## Exact integration base

PR 129 and the private-controller Azure runner from PR 134 are released on `main`.
Immediately before the latest integration rebase, `origin/main` resolved to `0bff0c9750853bc688c8c27a09de0b9ca0b1145b` and the implementation rebased onto that exact commit.
PR 130 targets `main`.
Remote PR head, remote branch, and `origin/main` remain authoritative and must be fetched again immediately before every later rebase or push.

## Implemented contract

The change keeps Crosscheck-specific execution, compartment, ledger-adapter, documentation, and focused tests in dedicated files:

- `bin/fm-crosscheck-azure.py`
- `bin/fm-crosscheck-azure-model-guest.sh`
- `bin/fm-crosscheck-azure-tool-bridge.py`
- `bin/fm-crosscheck-azure-replay.py`
- `docs/azure-crosscheck.md`
- `docs/azure-crosscheck/compartment.json`
- `tests/fm-crosscheck-azure.test.sh`

The obsolete model-side tool socket/client and generic command helper were removed.
The credentialed model VM now receives one bounded static packet containing the exact-base/exact-head diff, claims, and ledger projection, but no checkout or repository command tool.
Codex, Claude, and Pi launches explicitly disable command, MCP, extension, skill, and session surfaces as applicable.
The exact credential archive carries a generation-, harness-, model-, effort-, filename-, and content-digest-bound manifest; the guest validates it before use and deletes both archive and expanded credential before publishing a result.

Reviewer-supplied evidence returns only as bounded UTF-8 data.
The trusted host bridge validates its paths and exact command grammar, then delegates each accepted helper to two fresh `crosscheck-tool` runner invocations: one tool execution and one independent verifier replay.
Each repository child receives the exact advertised `refs/pull/<number>/head` snapshot, zero repository network, no provider credential, a sanitized environment, bounded output, and no trusted controller token.
The bridge rejects path traversal, absolute paths, symlink parents, pre-staged receipts, command suffix injection, malformed identities, source-ref drift, incomplete cleanup, VM/boot/resource reuse, truncation, and tool/verifier result disagreement.

The released runner gained a narrow `--public-ref` seam for an advertised branch head or `refs/pull/<number>/head`.
Preparation binds the candidate to that exact ref and commit; dispatch, retry, and the guest fetch re-prove it and fail closed if the ref moves.
The default released behavior remains a clean named branch reachable from exact public `main`.

The existing `bin/fm-crosscheck.py` integration remains narrow.
Its normal local evidence and mutation route is unchanged.
Azure supplies remote reproduction and pytest mutation executors; the latter validates patch scope locally without running project code, then proves a passing exact-head baseline and a failing mutated test in each fresh networkless tool/verifier VM.
Runners without a measured Azure non-execution classification remain CANNOT-CERTIFY rather than being mislabeled fixed.
The v2 finding lifecycle, exact live head and claims check, independent reviewer selection, readable report, and expected-head merge gate remain in their existing owner.
The Azure reviewer record now binds and revalidates the executing upstream account, review generation, request and evidence-attempt digests, exact PR-head source ref, every model/tool/verifier resource, VM and boot identity, every bounded result digest, and complete model, staging, tool, and verifier cleanup.

A separate CI timeout observed on behavior shard 8 was traced to the pause-absorption test's shallow process cleanup.
Its focused fixture now recursively stops and kills descendants before waiting, matching the established robust test-reaping pattern without changing watcher production behavior.

## Focused commands and outcomes

Only permitted focused checks were run:

```text
bash tests/fm-crosscheck-azure.test.sh
bash tests/fm-azure-runner.test.sh
bash tests/fm-watch-pause-absorb.test.sh
python3 -m py_compile bin/fm-crosscheck.py bin/fm-crosscheck-azure*.py bin/fm-azure-runner.py
bash -n bin/fm-crosscheck-azure-model-guest.sh bin/fm-azure-runner-guest.sh
python3 -m json.tool docs/azure-crosscheck/compartment.json
git diff --check
```

All named checks passed.
The focused coverage includes explicit Azure selection, static compartment boundaries, exact PR-ref and merge-base preparation and movement refusal, account-bound review generation, persisted identity and cleanup validation, hostile evidence paths, exact command injection refusal, symlink and symlink-parent denial, positive receipt execution, missing-marker refusal, positive pytest mutation certification, distinct tool/verifier attempts, stale endpoint/VM reuse refusal, private-controller secret noninheritance, and the behavior-shard process cleanup regression.

No no-mistakes command, full repository suite, shared validation-daemon operation, Azure apply, VM creation, cloud cleanup, PR merge, or default-branch push was performed.

## Live acceptance still owed

Live acceptance remains blocked until Firstmate reports the corrected released foundation safe for the exact reconciliation or invocation.
The complete required real PR, two-concurrent-review, fault-isolation, malicious-probe with positive controls, networkless replay, force-push invalidation, merge-gate, zero-residue, Mac-responsiveness, and cost sequence is in `docs/azure-crosscheck.md`.
The pinned model image, effective network policy, exact static-packet transport, private-controller evidence bridge, and zero-residue cleanup must all be exercised end to end on Azure Linux.
Until every leg passes, the implementation is a deployment candidate rather than a usable policy-grade service.
