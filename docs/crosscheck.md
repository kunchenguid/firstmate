# Crosscheck

Crosscheck is an independent exact-head finding ledger at the PR merge gate.
It is not a second implementation of tests, lint, documentation checks, pushing, PR creation, or CI.
No-mistakes remains the owner of that validation pipeline.

The review portion is intentionally close to "no-mistakes review with a fresh, different model."
Most of its review-quality value comes from that cross-model independence.
The separate mechanism earns its keep only through four contracts that no-mistakes does not currently own: durable finding lifecycle across runs, gate-executed reproduction evidence, gate-executed mutation proof for fixes, and an exact reviewed SHA passed atomically to GitHub at merge.
If those contracts move into no-mistakes, the separate reviewer runner should be removed rather than defended as a parallel product.

## Operator flow

Configure one or more policy-grade reviewer accounts per firstmate home.
The file is local and gitignored at `config/crosscheck-reviewer.json`.

```json
{
  "reviewers": [
    {
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/codex/home"
    },
    {
      "harness": "claude",
      "model": "claude-opus-5",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/claude/home"
    }
  ]
}
```

Crosscheck validates every configured entry and selects the first whose account home and model both differ from the author identity recorded in task metadata.
The accepted profiles are Codex `gpt-5.6-sol` xhigh and Claude `claude-opus-5` xhigh.
Absent configuration, unavailable credentials, missing model separation, and missing account separation all produce `CROSSCHECK UNREVIEWED` and a nonzero exit.

Start crosscheck as soon as a PR URL exists so it can overlap no-mistakes' remaining CI work.

```sh
bin/fm-crosscheck.sh run <task-id> <https://github.com/owner/repo/pull/number>
```

The run writes `data/<task-id>/crosscheck-ledger.json` and the readable `data/<task-id>/crosscheck.md` report.
The run exits zero only when the exact head has a complete review, the durable ledger has no active blocker, and the reviewer returned no unreproduced suspicion.

`bin/fm-pr-merge.sh` calls the verification form automatically after approval.
Do not call the verification form as a substitute for running a reviewer.

```sh
bin/fm-crosscheck.sh verify <task-id> <https://github.com/owner/repo/pull/number>
```

Verification re-reads the live PR head, base, and complete claims document.
It requires the latest attempt matching that head, base, and the stable PR number/title/body claims digest to be clear, then prints only the exact reviewed SHA.
Dynamic check counts in the full `gh-axi` document remain visible to the reviewer but are excluded from the digest so CI completing in parallel does not invalidate an otherwise exact review.
The merge helper sends that SHA in GitHub's atomic merge request.
A force-push before verification invalidates the ledger match, while a force-push after verification makes GitHub reject the expected-head merge request.

## Finding lifecycle

The ledger schema is `firstmate.crosscheck-ledger.v2`.
An existing ledger is validated before a reviewer runs.
A null, absent, or wrong-typed `findings` or `runs` collection is rejected rather than normalized.

Findings have exactly four lifecycle values.

- `open` means an executed reproduction admitted the defect and it remains a blocker.
- `claimed-fixed` records a reviewer's claim but remains a blocker.
- `verified-fixed` requires a tracked named test that passes on the exact head and fails after a supplied implementation mutation is applied.
- `closed-equivalent` requires a direct reference to another currently `verified-fixed` finding.

A later review that omits a finding leaves its lifecycle unchanged.
Silence never closes, supersedes, or deletes a finding.
A `verified-fixed` lifecycle remains durable, but its proof clears only the exact head on which the gate executed it; a new head requires a fresh mutation proof.

New findings must supply a helper under `.crosscheck/reproductions/`, a command naming that helper, an expected exit code, and a distinctive output marker.
Crosscheck executes the command itself and stores its actual exit and bounded output in the ledger.

A `verified-fixed` update must name a tracked test and provide an implementation-only patch under `.crosscheck/mutations/`.
It supplies an approved test runner plus a structured argument array, never a free-form shell command.
Crosscheck creates one clean checkout at the exact reviewed head, confirms the named test passes, destroys the entire checkout, recreates the same path from the exact head, applies the patch, and requires the same test to fail.
Destroying all readable baseline state before the mutated run prevents a test from manufacturing causality through a predictable sibling checkout.
Proof sandboxes also omit shared POSIX IPC and give each run private writable temporary and cache state, while shared host temporary directories remain outside the write policy.
The named test must be a canonical tracked regular file; symlinks are rejected so a patch cannot mutate the executed target through an unchanged alias.
The gate positions the tracked test path itself as the interpreter script or test-framework target; generic command launchers are not approved runners.
The patch may modify only non-test implementation paths already cited by the durable finding.
It cannot modify the named test, conventional test trees, fixtures, or Crosscheck evidence support.

## Refusal and liveness

The reviewer is a synchronous Codex or Claude invocation with a bounded timeout and a JSON output schema.
PR claims are delimited as untrusted data, and the reviewer is directed to ignore embedded instructions and use focused evidence rather than duplicate no-mistakes' broad suite.
Later reviewers receive only a bounded projection of finding IDs, lifecycle state, severity, exact-head clearance, and proof digests.
Finding prose, reproduction output, test output, and lifecycle notes remain durable in the ledger but are never reinjected into a later reviewer prompt.
The Codex path pins `gpt-5.6-sol`, xhigh reasoning, noninteractive approval, an independent `CODEX_HOME`, and the exact review checkout.
The Claude path pins `claude-opus-5`, xhigh effort, the installed unattended `--dangerously-skip-permissions` mode, a bounded tool list, no session persistence, an independent `CLAUDE_CONFIG_DIR`, and structured JSON output.
Because that Claude mode disables its own permission prompts, Crosscheck places the process under the installed macOS `sandbox-exec` contract: reads, process execution, and provider network access remain available, while writes are limited to the disposable review checkout and `/dev/null`.
An unavailable sandbox blocks the reviewer rather than launching it with ambient write authority.
A nonzero exit, timeout, missing artifact, empty artifact, malformed artifact, wrong-head artifact, or unresolved suspicion records an `unreviewed` attempt and exits nonzero.
This includes provider refusals that surface only as a stopped or silent agent.
Reviewer and evidence stdout plus stderr share a 200,000-byte capture ceiling; crossing it terminates the owned process tree and records a loud `unreviewed` attempt.
The final wait and identity-pinned descendant cleanup remain inside the same absolute deadline.
Structured verdict artifacts are stable regular files bounded by the same byte ceiling before JSON decoding.
The durable ledger is bounded separately and fails closed when absent, symlinked, malformed, non-finite, or oversized.
The platform-specific containment limits and empirical mutation evidence are recorded in [crosscheck-bounded-io.md](crosscheck-bounded-io.md).
Reviewer result arrays are capped at 32 entries, at most 32 evidence executions are accepted, and all reproduction and mutation work shares a 900-second aggregate deadline by default.

## Installed external contracts

The external surface was observed on 2026-08-02 before implementation, rechecked on 2026-08-03 for nonempty TOON arrays, and re-run against installed `gh-axi 0.1.25` on 2026-08-04.
The current recheck observed `gh-axi 0.1.25`, `codex-cli 0.146.0-alpha.9.2`, and Claude Code 2.1.221; the original Claude contract was first exercised on 2.1.220.

`gh-axi pr view` supports `--full` but does not support raw-gh `--json` or `-q` flags.
The production adapter therefore uses these exact forms.

```sh
gh-axi api /repos/<owner>/<repo>/pulls/<number>
gh-axi pr view <number> --repo <owner>/<repo> --full
gh-axi api PUT /repos/<owner>/<repo>/pulls/<number>/merge \
  --field sha=<reviewed-40-hex-sha> \
  --field merge_method=<merge|squash|rebase>
```

The checked-in TOON fixtures under `tests/fixtures/gh-axi-v0.1.25-*.toon` are reduced from those observed documents.
Every GitHub fake rejects command forms outside this surface.
The `labels[1]{id,name,color,default,description}:` table in the PR API fixture was observed from installed `gh-axi 0.1.25` with `gh-axi api /repos/lance-format/lance/pulls/8166` on 2026-08-03.
The 2026-08-04 recheck used `gh-axi api /repos/ruby-dlee/firstmate/pulls/72` and observed head `c9cbe79154013efcec9aa478f1476d0eff6c63df`, base `68f014697d0eea733a4e7c0294becff4e76c7bcf`, and `merged: true` in the installed TOON shape.
It also confirmed from `gh-axi pr view --help` that view still accepts only `--comments`, `--reviews`, and `--full`, while `gh-axi api --help` still accepts `GET`, `POST`, `PUT`, `PATCH`, `DELETE`, and `HEAD` with repeated `--field` values.
The merge form with optional `commit_title` and `commit_message` fields was separately exercised against an already-merged PR and returned the observed successful no-op response.
The read adapter exposes no merge subcommand; only the gate-refused `fm-crosscheck.sh merge` boundary can reach its private exact-SHA merge primitive, and that boundary freshly verifies the ledger before issuing the request.

The installed reviewer invocation was exercised successfully with `--output-schema`, `--output-last-message`, `--model gpt-5.6-sol`, and `model_reasoning_effort="xhigh"` before production code used those flags.
The installed Claude invocation was exercised successfully with `--model claude-opus-5`, `--effort xhigh`, `--dangerously-skip-permissions`, `--tools Bash,Read,Write,Edit,Glob,Grep`, `--no-session-persistence`, `--output-format json`, and `--json-schema` before production code used those flags.
The installed `/usr/bin/sandbox-exec` was also exercised with the generated profile: a write inside the allowed review directory succeeded, while sibling and `/private/tmp` writes failed with `Operation not permitted`.

## Validation evidence boundaries

`tests/fm-github-pr.test.sh` is hermetic coverage using checked-in TOON shapes observed from installed `gh-axi 0.1.25`.
Most of `tests/fm-crosscheck.test.sh` is hermetic coverage using observed-shape GitHub, Codex, Claude, and sandbox fakes.
Its `test_installed_sandbox_denies_shared_private_tmp` case is the exception: it invokes the real installed `/usr/bin/sandbox-exec` and verifies the generated proof profile denies shared host temporary state.
Its `test_forged_git_diff_mutation_command_is_rejected` case is the named regression that fails if a free-form `git diff --quiet # tests/regression.test.sh` can replace real mutation verification.
Its `test_baseline_readable_state_is_destroyed_before_mutation` and `test_mutation_is_bound_to_cited_non_test_implementation` cases cover the two mutation-causality bypasses found in the final review round.
`tests/fm-github-pr.test.sh` includes named cases for fieldless-array grammar, complete timeout-child cleanup, and refusal of the former public merge subcommand.
The focused PR-check cases in `tests/fm-teardown-suite.sh` and the merge cases in `tests/fm-pr-merge.test.sh` also use observed-shape GitHub fakes.
Those deterministic suites validate parsing, lifecycle, failure handling, and atomic request construction; they do not claim to exercise live provider availability.
The real installed-tool exercise is separate and network-dependent: the dated `gh-axi` observations above cover successful documents, while an adapter lookup for an absent PR through installed `gh-axi` must exit nonzero with `GitHub state is unreviewed`.

## Deliberate limitations

Crosscheck supports immediate `merge`, `squash`, and `rebase` methods plus commit title and body fields.
It rejects `--auto` because an asynchronous merge would escape the immediate expected-head request.
It rejects `--delete-branch` because branch deletion is not part of the atomic merge operation.
Delete a branch only in a later separately authorized action after the merge is confirmed.

Reviewer-generated commands execute in disposable exact-head clones with bounded timeouts.
Codex uses its installed workspace-write sandbox, and Claude uses the explicit macOS profile described above.
Both permit test processes and provider network access, so this is containment for accidental or prompt-directed file mutation, not a guarantee that hostile repository code is safe to execute.
