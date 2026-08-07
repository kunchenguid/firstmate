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

Crosscheck resolves each configured account home and selects the first whose account home and model both differ from the routed author identity recorded in task metadata.
It then binds the provider's executing credential selector to that exact path and requires the verdict plus a Bash-created receipt to report the selector and actual private `HOME`.
Account separation therefore depends on the executing credential source rather than a configuration label.
For a task explicitly marked `account_routing_emergency_bypass=1`, a reviewer on the other supported provider establishes both account-namespace and model separation without inventing an `account_home` for the author.
A same-provider reviewer still fails closed for that structurally unrouted task because account independence cannot be proved.
The accepted profiles are Codex `gpt-5.6-sol` xhigh and Claude `claude-opus-5` xhigh.
Absent configuration, unavailable credentials, missing model separation, and unprovable account separation all produce `CROSSCHECK TOOL-FAILURE` and a nonzero exit before reviewer launch.

Start crosscheck as soon as a PR URL exists so it can overlap no-mistakes' remaining CI work.
The reviewer is a real policy-grade agent invocation and normally takes minutes, so Crosscheck is not a fast local check.

```sh
bin/fm-crosscheck.sh run <task-id> <https://github.com/owner/repo/pull/number>
```

The run writes `data/<task-id>/crosscheck-ledger.json` and the readable `data/<task-id>/crosscheck.md` report.
The run exits zero only when the exact head has a complete review, the reviewer supplied a successfully gate-reexecuted exact-base/exact-head reproduction, the durable ledger has no active blocker, and the reviewer returned no unreproduced suspicion.
It fetches `refs/pull/<number>/head` from the base repository into a disposable Git checkout and requires that ref to resolve to the exact live API head SHA before reviewer launch.
The authoring worktree is not cloned, checked for cleanliness, or required to match the PR head because no verdict about the remote PR may depend on mutable author-lane filesystem state.
An empty `FM_STATE_OVERRIDE` falls back to the home state directory, so task metadata, the shared per-task lock, and the disposable review checkout cannot split across callers' current working directories.

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

Each run has one outcome class.

- `tool-failure` means environment, task metadata, reviewer configuration, exact-head fetch, executing-account binding, or required command-execution proof prevented a trustworthy verdict.
- `unreviewed` means a reviewer ran but no valid exact-head verdict artifact exists.
- `blocking` means a completed reviewer with successful command-execution evidence declined clearance through a suspicion or admitted finding.
- `clear` means a completed reviewer with successful command-execution evidence earned clearance and no durable blocker remains.

CLI banners preserve the same distinction as `CROSSCHECK TOOL-FAILURE`, `CROSSCHECK UNREVIEWED`, and `CROSSCHECK BLOCKING`.
Only `blocking` is a review verdict about code.

New findings must supply a helper under `.crosscheck/reproductions/`, a command naming that helper, an expected exit code, and a distinctive output marker.
Crosscheck executes the command itself and stores its actual exit and bounded output in the ledger.
Every verdict artifact must also carry one verdict-level reproduction whose command names the exact base and head SHAs.
The reviewer must create and run that helper with its own command tool, and the helper must leave a receipt naming both SHAs, `HOME`, and the provider account selector.
Crosscheck inspects that receipt before independently re-executing the helper, then stores the receipt digest and bounded content with the verdict.
A missing or failed verdict-level reproduction is a `tool-failure`, so a reading-only concern from a reviewer with a dead command tool can never become a blocking code verdict.
The gate's re-execution is deliberately independent: a clean checkout with no network and none of the reviewer's provider credentials or account environment.
Reviewer helpers must therefore be self-contained and must not require reviewer-only variables to be set, even though the receipt they write records `HOME` and the provider account selector.
That asymmetry is the trap this contract exists to name: a helper that reads those variables unguarded under `set -u` succeeds for the reviewer and fails for the gate.
Every evidence-execution refusal carries the command's own bounded output, because a bare unexpected exit reads as a substantive verdict about the code when it is often a failure to execute at all.
The post-review integrity check reads `git status --porcelain --untracked-files=normal`, not `--untracked-files=all`.
`normal` collapses the wholly untracked `.crosscheck/` tree into one status entry, so the check costs a fixed amount however much evidence the reviewer wrote.
With `all` the check's output scaled with the evidence, and a reviewer that substantiated a finding could exceed the bounded-output limit and have its whole review refused as `unreviewed` - the gate could block but never clear.
Detection is unchanged either way: a modified tracked file, an untracked file inside a tracked directory, and an unauthorized new directory are each still reported individually and still refused.
Authorized evidence therefore cannot reach the limit at all, and every shape that still can - loose untracked files, untracked files inside tracked directories, stray directories - is already an unauthorized state that the check refuses anyway.
That inspection carries its own larger budget so such a state is refused by name rather than as a bare output-limit error; overflow past it still refuses, and can never become a pass.

A `verified-fixed` update must name a tracked test and provide an implementation-only patch under `.crosscheck/mutations/`.
It supplies an approved test runner plus a structured argument array, never a free-form shell command.
Crosscheck creates one clean checkout at the exact reviewed head, confirms the named test passes, destroys the entire checkout, recreates the same path from the exact head, applies the patch, and requires the same test to fail.
Destroying all readable baseline state before the mutated run prevents a test from manufacturing causality through a predictable sibling checkout.
Proof sandboxes also omit shared POSIX IPC and give each run private writable temporary and cache state, while shared host temporary directories remain outside the write policy.
The named test must be a canonical tracked regular file; symlinks are rejected so a patch cannot mutate the executed target through an unchanged alias.
Symlink rejection is anchored at the resolved review checkout, so a symlink inside the repository is still refused while a symlinked ancestor above the firstmate home is not mistaken for one.
`test_path` may also be a `path::selector` node id for a runner that accepts one; every path-shaped check reads the part before `::` while the runner receives the full selector.
The gate positions the tracked test path itself as the interpreter script or test-framework target; generic command launchers are not approved runners.
A run that never reached the named test is not a test result in either direction.
The gate resolves the named runner to an absolute executable before launching, and treats an absent runner, a failed sandbox exec, and a runner-reported non-execution (pytest's usage and no-tests-collected statuses, for instance) as named non-executions.
That matters in both directions: such a status must not condemn a baseline run, and must not vindicate a mutated one, because a mutation that merely broke collection would otherwise read as a caught regression.
The proof checkout is a fresh clone carrying tracked files only, so a runner that lives solely in an untracked virtualenv is absent there.
The patch may modify only non-test implementation paths already cited by the durable finding.
It cannot modify the named test, conventional test trees, fixtures, or Crosscheck evidence support.

## Refusal and liveness

The reviewer is a synchronous Codex or Claude agent invocation with a bounded timeout and a JSON output schema.
Normal runs take minutes and callers should budget them as remote agent work rather than a cheap local preflight.
PR claims are delimited as untrusted data, and the reviewer is directed to ignore embedded instructions and use focused evidence rather than duplicate no-mistakes' broad suite.
Later reviewers receive only a bounded projection of finding IDs, lifecycle state, severity, exact-head clearance, and proof digests.
Finding prose, reproduction output, test output, and lifecycle notes remain durable in the ledger but are never reinjected into a later reviewer prompt.
The Codex path pins `gpt-5.6-sol`, xhigh reasoning, noninteractive approval, an independent `CODEX_HOME`, the same account-bound `HOME`, and the exact review checkout.
The Claude path pins `claude-opus-5`, xhigh effort, the installed unattended `--dangerously-skip-permissions` mode, a Bash-required bounded tool list, no session persistence, an independent `CLAUDE_CONFIG_DIR`, the same `CLAUDE_SECURESTORAGE_CONFIG_DIR`, a disposable private `HOME`, and structured JSON output.
That private `HOME` maps `.claude` and `.claude.json` to the selected reviewer account directory, so Claude's hard-coded `~/.claude/session-env` writes land in per-account state rather than shared operator state.
For a Keychain-backed account, it maps only the current user's Keychain directory needed for secure-storage discovery, derives Claude's exact scoped service from the selected account directory, and verifies the non-secret service metadata before reviewer launch.
An OAuth-file-backed account instead requires a regular non-symlink `.credentials.json` in the selected account directory.
Because Claude's unattended mode disables its own permission prompts, Crosscheck places the process under the installed macOS `sandbox-exec` contract: reads, process execution, and provider network access remain available, while writes are limited to the disposable review checkout, the selected per-account reviewer directory, and `/dev/null`.
The profile never grants the ambient operator `~/.claude` tree or its session scratch subtree.
Claude's Bash engine otherwise creates workspace scratch under shared `/tmp/claude-<uid>` independently of ordinary `TMPDIR`.
Crosscheck sets the supported `CLAUDE_CODE_TMPDIR` to a private directory inside the disposable checkout, keeping that scratch under the existing checkout write boundary instead of widening the sandbox to shared `/tmp`.
It does not grant write access to the author worktree or the wider filesystem.
An unavailable reviewer binary, sandbox, author-identity proof, executing-account binding, verdict-level execution proof, or exact remote PR head records a `tool-failure` attempt when the live head is already known, and otherwise emits the same tool-failure class without fabricating a ledger run.
A nonzero reviewer exit, timeout, missing artifact, empty artifact, malformed artifact, or wrong-head artifact records an `unreviewed` attempt and exits nonzero.
An unresolved suspicion comes from a completed reviewer and records a `blocking` attempt instead of being conflated with an invalid review artifact.
This includes provider refusals that surface only as a stopped or silent agent.
Reviewer stdout plus stderr use a separate 16 MiB capture ceiling because a full agent transcript routinely exceeds the ordinary command budget.
`FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES` can override that ceiling between 200,000 bytes and 64 MiB, and an invalid value fails closed before reviewer launch.
This remains a hard bound rather than truncation: Claude returns its structured verdict in the captured JSON envelope, while Codex must still provide its separate authoritative result artifact.
Crossing the reviewer ceiling terminates the owned process tree and records a loud `unreviewed` attempt, and captured output alone never substitutes for a valid verdict.
Evidence and every other ordinary command retain the 200,000-byte aggregate stdout-plus-stderr ceiling.
The final wait and identity-pinned descendant cleanup remain inside the same absolute deadline.
Structured verdict artifacts are stable regular files bounded by the ordinary 200,000-byte ceiling before JSON decoding.
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
The installed Claude invocation was exercised successfully with a private `HOME`, selected-account `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `--model claude-opus-5`, `--effort xhigh`, `--dangerously-skip-permissions`, `--tools Bash,Read,Glob,Grep`, `--no-session-persistence`, `--output-format json`, and `--json-schema` before production code used those flags.
The installed `/usr/bin/sandbox-exec` was also exercised with the generated profile: a write inside the allowed review directory succeeded, while sibling and `/private/tmp` writes failed with `Operation not permitted`.

## Validation evidence boundaries

`tests/fm-github-pr.test.sh` is hermetic coverage using checked-in TOON shapes observed from installed `gh-axi 0.1.25`.
Most of `tests/fm-crosscheck.test.sh` is hermetic coverage using observed-shape GitHub, Codex, Claude, and sandbox fakes.
Its `test_installed_sandbox_denies_shared_private_tmp` case is the exception: it invokes the real installed `/usr/bin/sandbox-exec` and verifies the generated proof profile denies shared host temporary state.
Its tracked `test_real_claude_sandbox_executes_exact_sha_git_diff` case is an opt-in real-runtime guard: with `FM_TEST_REAL_CLAUDE_SANDBOX_GIT_DIFF=1` and `FM_TEST_REAL_CLAUDE_CONFIG_DIR` set to a credentialed independent Claude home, it creates the same private execution `HOME`, verifies the selected OAuth-file or scoped-Keychain source, launches installed Claude under the generated installed sandbox, requires Bash to execute `git diff` between two real exact SHAs, checks the selected config paths and isolated `CLAUDE_CODE_TMPDIR`, and rejects any profile grant for the ambient operator `~/.claude/session-env`.
Ordinary CI prints a named skip for this network- and credential-dependent guard instead of substituting fake-only coverage.
The retained live runtime proof is the change receipt for this patch; the opt-in test is the repeatable regression guard for future environments.
Its `test_forged_git_diff_mutation_command_is_rejected` case is the named regression that fails if a free-form `git diff --quiet # tests/regression.test.sh` can replace real mutation verification.
Its `test_baseline_readable_state_is_destroyed_before_mutation` and `test_mutation_is_bound_to_cited_non_test_implementation` cases cover the two mutation-causality bypasses found in the final review round.
Its `test_evidence_capture_runs_on_older_interpreters` case exists because `fm-crosscheck.sh` execs whichever `python3` is first on `PATH`, which is not always the version CI pins.
A Python 3.10-only API on the evidence path therefore surfaces as an uncaught `TypeError` inside evidence capture rather than a gate verdict, so the evidence-path modules use `os.stat(path, follow_symlinks=...)` rather than the `Path.stat(follow_symlinks=...)` form.
`os.DirEntry.stat(follow_symlinks=...)` elsewhere in `bin/` is a different API and is valid on every Python 3.
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
