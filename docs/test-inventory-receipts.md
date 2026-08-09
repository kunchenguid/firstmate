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
Its GraphQL response must contain exactly one base-branch protection entry.
The boundary captures that exact raw response before `gh-axi` normalization can collapse duplicate JSON keys or discard its error envelope.
For the literal-null path, any top-level GraphQL error or structurally unexpected response envelope fails closed before protection data is interpreted.
A structured protection rule remains supported only when it contains exactly one `requiresStrictStatusChecks` value and one `isAdminEnforced` value, both `true`.
A literal `branchProtectionRule: null` is the one sanctioned unprotected-repository path and does not synthesize strict or administrator values.
Selecting that path emits an explicit diagnostic before proceeding.
Missing, duplicate, non-null scalar, partial-object, or null-with-child protection data is malformed or ambiguous and fails closed.
Both protection paths verify the requested canonical PR identity, current exact head and base OIDs, and candidate ancestry.
Immediately before an unprotected mutation, the boundary re-reads the PR and refuses any identity, head, base, state, or protection-data drift, then rechecks that the clean local worktree remains at the exact head.
The merge mutation is conditioned on that exact expected-head SHA, and both paths require GitHub to confirm that it merged the conditional request.
GitHub's merge API exposes an expected-head precondition but no expected-base OID precondition.
The unprotected response must also identify the resulting commit.
For the unprotected path, the boundary immediately re-reads the base ref after mutation and requires it to point to GitHub's reported result commit.
Method-specific parent or history validation must attribute that result to the exact pre-mutation base and expected-head candidate.
The unprotected rebase path rejects candidates containing originally empty commits because GitHub drops them and their missing rewrite can conceal unrelated mutation-time base advancement from this bounded history check.
These adjacent pre-mutation and post-mutation base observations bound but cannot eliminate every residual external-writer race.
That remaining window assumes Firstmate is the single merge authority and no concurrent uncooperative writer advances the base.
The unprotected path does not claim that GitHub enforces required status checks; it preserves the exact-candidate boundary after the delivery lifecycle has established that the candidate's checks are green.

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
