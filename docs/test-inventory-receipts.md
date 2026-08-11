# Test-inventory receipts

This document owns Firstmate's literal-source test-inventory receipt contract and its merge-time enforcement model.
Every project merged by Firstmate declares either `test-bearing` or `testless` in `.firstmate/test-inventory.json`.
The shared merge boundary always rejects a missing declaration at the exact candidate and normally requires the exact base to carry the prior declaration.

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
The normal repository proof remains one shared Git common directory for the task worktree and project checkout.
A PR task may instead use a pooled worktree from another clone only when the metadata project is either the active Firstmate home root for a project-less secondmate or one immediate child of that home's `projects/` directory for a provisioned project.
No sibling of the home root, nested project path, or project from another home satisfies this ownership proof.
[`bin/fm-home-seed.sh`](../bin/fm-home-seed.sh) owns both exact home shapes and the clone source, so this exceptional proof reads exactly one local `remote.origin.url` from each clone and accepts only an unambiguous `github.com` HTTP(S), SSH, or SCP-style URL.
The typed identity contains the provider, host, and case-folded owner/repository slug, while every non-origin remote is deliberately non-authoritative.
Missing, duplicate, unsupported-host, different-owner, different-repository, and cross-home project evidence fails closed before any merge mutation.
Local-only landing still requires one shared Git common directory and never uses cross-clone equivalence.
Immediately before a cross-clone GitHub mutation, the boundary revalidates the task metadata, active-home ownership, both Git common directories, both canonical origin identities, and the requested PR repository identity.
This source-identity proof does not replace no-mistakes' separate canonical delivery-target selection, change which home supplies GitHub credentials, or relax exact-head and canonical PR checks.
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

## Candidate-carried bootstrap transition

When and only when `.firstmate/test-inventory.json` is absent from the exact merge-base tree, `merge-check` may use the exact reviewed candidate as the initial inventory policy.
An unreadable, malformed, ambiguous, or non-regular base declaration is not absence and does not qualify for bootstrap.
The candidate must carry a regular, unambiguous declaration that satisfies the existing inventory contract.
A `test-bearing` candidate must carry its required literal-source receipt, while a `testless` candidate must carry no receipt.
Duplicate JSON object keys are ambiguous and are rejected.
The worktree declaration and any required receipt must equal the versions committed in the exact candidate tree, and the existing receipt verifier must match the receipt's declaration digest, baseline version, counts, and literal-declaration digest to that tree.
Missing, malformed, ambiguous, or inconsistent candidate material fails before any merge mutation.

This is a one-transition compatibility path.
After the seed lands, the next exact merge base contains the declaration, so every later candidate returns to the existing declaration-transition verification, including baseline-version and reduction-review rules.
The bootstrap never treats inventory as optional and never permits a test-bearing candidate to omit or bypass its receipt.

Only the inventory policy's starting point changes during this transition.
PR identity, exact head and base OIDs, candidate ancestry, local exact-head and clean-state checks, repository-eligibility checks, SHA-conditional GitHub mutation, and post-mutation exact-candidate confirmation remain owned and enforced by the shared merge boundary.
Protected and separately sanctioned explicit-null unprotected repository paths retain their existing eligibility rules.

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

For a Git worktree, `collect` and `check` require the checkout root and enumerate only regular stage-0 literal-test paths and blobs from that worktree's index.
They write and report `source_tree=git-index`, so ignored nested repositories and untracked test files cannot contribute to a receipt.
Running either command from a subdirectory of a Git checkout fails instead of falling back to filesystem traversal.
An input that is intentionally outside a Git worktree remains supported and is explicitly marked `source_tree=filesystem`.
`merge-check` accepts only receipts marked `source_tree=git-index` and separately verifies the exact committed candidate tree.

The receipt binds the declaration digest, baseline version, declaration count, test-file count, and a SHA-256 digest of sorted literal declaration identifiers.
Dynamic parametrization, generated tests, custom collection hooks, and other runtime behavior are intentionally outside this receipt's guarantee.
In particular, a candidate-controlled `conftest.py` that could forge a runtime observer is outside the threat model because this contract never executes it.
[`tests/fm-test-inventory.test.sh`](../tests/fm-test-inventory.test.sh) is the focused regression for that no-execution boundary.

A changed baseline policy advances `baseline.version`.
`maximum_unreviewed_deletion` lowers both the declaration-count and test-file-count floors by the stated allowance; decreasing either baseline count or increasing that allowance also records `baseline_reduction_review` with the prior version and counts, reviewer, date, and reason.
Changing between `test-bearing` and `testless` is refused at this boundary and requires a separately reviewed migration.
Testless projects declare only `schema_version` and `status` and keep no receipt.

## Rollout

Prefer seeding the declaration and receipt on the target branch before enabling Firstmate merge enforcement for the project.
If enforcement is already active while the exact base predates the declaration, use the candidate-carried bootstrap transition above exactly once.
Commit the declaration and generated receipt together for a test-bearing project, or only the declaration for a testless project.
For a Git project, stage changed literal Python test source, then run `$FM_ROOT/bin/fm-test-inventory.sh collect .` from the checkout root and commit the regenerated receipt.
For an intentional non-Git input, `collect` remains available and marks its receipt `source_tree=filesystem`; that receipt cannot satisfy Git merge verification.
