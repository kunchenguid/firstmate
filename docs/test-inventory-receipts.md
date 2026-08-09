# Test-inventory receipts

This document owns Firstmate's literal-source test-inventory receipt contract and its merge-time enforcement model.
Every project merged by Firstmate declares either `test-bearing` or `testless` in `.firstmate/test-inventory.json`.
The shared merge boundary rejects a missing declaration at the exact candidate or base.

## One merge execution boundary

Every sanctioned merge entry point delegates its final operation to [`bin/fm-merge-execute.sh`](../bin/fm-merge-execute.sh).
`fm-pr-merge.sh` records forge metadata before delegating GitHub execution, while `fm-merge-local.sh` delegates approved local-only execution.
The boundary verifies clean exact candidate and base commits, then verifies the committed declaration and receipt against the candidate's literal Python source before it merges.
The local path lets Git own the checkout and ref transition while its prepared reference transaction verifies the expected default ref, base, and candidate on a quiescent project checkout.
Concurrent uncooperative writers to that project checkout during landing are outside the supported boundary; best-effort dirty-state checks refuse detected drift but do not provide cross-writer atomicity.
The GitHub path submits an immediate REST merge conditioned on the verified head SHA.
GitHub execution requires strict, administrator-enforced base-branch protection so the conditional merge cannot bypass required status checks.

## Literal-source inventory

A test-bearing declaration records a baseline for literal Python test declarations.

```json
{
  "schema_version": 1,
  "status": "test-bearing",
  "baseline": {
    "version": 1,
    "declarations": 57,
    "test_files": 8
  },
  "maximum_unreviewed_deletion": 0
}
```

[`bin/fm-test-inventory.sh`](../bin/fm-test-inventory.sh) recognizes only top-level `test_*` functions and `test_*` methods of top-level `Test*` classes in `test_*.py` and `*_test.py` files.
It does not import the project, run pytest, execute plugins, or claim to observe the runtime test suite.
`collect` writes the receipt and `check` compares the receipt with the current literal source.

The receipt binds the declaration digest, baseline version, declaration count, test-file count, and a SHA-256 digest of sorted literal declaration identifiers.
Dynamic parametrization, generated tests, custom collection hooks, and other runtime behavior are intentionally outside this receipt's guarantee.
In particular, a candidate-controlled `conftest.py` that could forge a runtime observer is outside the threat model because this contract never executes it.
[`tests/fm-test-inventory.test.sh`](../tests/fm-test-inventory.test.sh) is the focused regression for that no-execution boundary.

A changed baseline policy advances `baseline.version`.
`maximum_unreviewed_deletion` lowers both the declaration-count and test-file-count floors by the stated allowance; decreasing either baseline count or increasing that allowance also records `baseline_reduction_review` with the prior version and counts, reviewer, date, and reason.
Changing between `test-bearing` and `testless` is refused at this boundary and requires a separately reviewed migration.
Testless projects declare only `schema_version` and `status` and keep no receipt.

## Rollout

Seed the declaration and receipt on the target branch before enabling Firstmate merge enforcement for the project.
Commit the declaration and generated receipt together for a test-bearing project, or only the declaration for a testless project.
Run `$FM_ROOT/bin/fm-test-inventory.sh collect .` after changing literal test declarations, then commit the regenerated receipt.
