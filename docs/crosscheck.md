# Crosscheck

Crosscheck is an independent exact-head finding ledger at the PR merge gate.
It is not a second implementation of tests, lint, documentation checks, pushing, PR creation, or CI.
No-mistakes remains the owner of that validation pipeline.

By default, the review portion is intentionally close to "no-mistakes review with a fresh, different model."
Most of its review-quality value comes from that cross-model independence.
A home can explicitly accept reduced model independence for a proven-separate reviewer account, but the evidence always identifies that weaker mode.
For exact pre-snapshot Pi work that genuinely cannot be replaced under a newly bound author lane, a last-resort local admission can acknowledge that historical author-account independence is unproven; it never turns current credentials into invented historical proof, and the evidence labels that weaker mode too.
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
    },
    {
      "harness": "pi",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/pi/home"
    }
  ]
}
```

Crosscheck resolves each configured account home and keeps every entry that satisfies the home's model policy and either proves account separation or carries an exact legacy-author admission, in configured order.
Model separation is mandatory by default.
The optional local `config/crosscheck-same-model` file relaxes only that screen when it contains exactly `on`; an absent file or exactly `off` preserves the default, and any other value or unsafe file shape is refused.
This setting is local and gitignored, is read fresh for each reviewer selection, and is not inferred from the reviewer roster or environment.
It does not weaken account separation: the same upstream account and an unreadable identity remain ineligible even when the setting is on.
A selected same-model reviewer receives a visible reduced-independence prompt that directs it to attack the change adversarially, falsify the author's claims instead of confirming them, and report a finding when uncertain.
Its ledger reviewer record carries `model_independence: same-model`, and the readable report labels the run `SAME-MODEL` so the reduced independence cannot be mistaken for a cross-model review.

The primary recovery for Pi work created before launch-bound identity snapshots is **replacement under a newly bound author lane**, not admission.
Create a normal new Pi ship lane after the snapshot support landed, require its metadata to carry the launch-bound `author_account_identity`, have that lane inspect and take ownership of the complete intended change on a fresh base, revalidate it, and publish a replacement commit to the existing writable PR branch.
Run Crosscheck for the replacement head with the new lane's task id.
That gives the gate real author-account proof and keeps the ordinary separation rule intact.
Copying an account id into old metadata is never part of this path, and merely relabeling the old task is not re-authorship.
The old lane or worktree being gone is not by itself a reason for admission when the PR branch can still accept a replacement.

`config/crosscheck-legacy-author-admissions.json` is the last-resort relaxation for a pre-snapshot Pi head that genuinely cannot be replaced under a newly bound lane, such as a PR branch the fleet cannot write or a head whose required provenance cannot be rewritten.
It is local, gitignored, read fresh at reviewer preflight, and absent means no admission.
There is no global on switch.
Each entry admits exactly one task, canonical PR URL, and live head SHA, and must repeat the Pi harness and provider-slot-prefixed model recorded in task metadata.
It also requires an exact UTC approval time, literal `legacy_author_provenance: pre-snapshot-pi`, literal `replacement_unavailable: true`, one printable-line `replacement_unavailable_reason`, and literal `admit_unproven_author_account: true` acknowledgement.
The whole file is validated and unsafe shapes fail closed.

```json
{
  "admissions": [
    {
      "task_id": "pause-vs-orphan-run-p6",
      "pull_request": "https://github.com/ruby-dlee/firstmate/pull/116",
      "head_sha": "0123456789abcdef0123456789abcdef01234567",
      "author_harness": "pi",
      "author_model": "openai-codex-5/gpt-5.6-sol",
      "approved_at": "2026-08-10T12:00:00Z",
      "legacy_author_provenance": "pre-snapshot-pi",
      "replacement_unavailable": true,
      "replacement_unavailable_reason": "PR branch is not writable by this fleet; exact-head replacement cannot be published.",
      "admit_unproven_author_account": true
    }
  ]
}
```

A matching entry is accepted only when task metadata still names an account-less Pi lane with no `author_account_identity` and no modern `author_identity_snapshot_epoch` marker.
Every new Pi launch under snapshot-aware code records `author_identity_snapshot_epoch: launch-bound-v1` even when credential capture fails.
Recovery preserves that marker only when the prior metadata already carried it, including after a later capture failure or account change, and never mints it for a legacy lane.
The admission contributes the positive `pre-snapshot-pi` provenance assertion.
It cannot downgrade routed work or a modern Pi snapshot, and a head change requires an explicitly renewed entry.
The rule never populates metadata and never derives the old author from today's mutable provider-slot credential.
It requires the selected reviewer to expose a readable executing account, hashes that identity at selection, and rechecks the hash against the launch-bound credential immediately before review.
That binds who reviewed without pretending that reviewer differs from the unknowable historical author.
The prompt says plainly that the reviewer may use the author's upstream account, removes the ordinary claim that the reviewer is account-independent, and demands disconfirming evidence.
The ledger records `author_account_independence: unproven-legacy-admission`, the admission digest, approval time, pre-snapshot provenance, replacement-unavailable attestation and reason, historical harness/model, and reviewer-account digest.
The readable report labels `LEGACY AUTHOR ACCOUNT UNPROVEN` and repeats the admission digest, time, provenance, historical harness/model, reviewer identity digest, and replacement-unavailable reason.
When the same-model option also applies, both warnings and both evidence labels remain visible.

Crosscheck then binds the provider's executing credential selector to that exact path and requires the verdict plus a Bash-created receipt to report the selector and actual private `HOME`.
Account separation therefore depends on the executing credential source rather than a configuration label.
Every reviewer disables reviewed-repository instruction discovery at launch: Codex sets `project_doc_max_bytes=0`, Claude uses `--safe-mode`, and Pi uses `--no-context-files`.
Pi is launched through the resolved installed executable with `openai-codex/gpt-5.6-sol` at `xhigh`, JSON event output, an ephemeral session, and only the read and Bash-capable review tools.
For the installed npm entrypoint, Crosscheck also resolves Pi's sibling Node runtime before launch instead of allowing the reviewer environment's `PATH` to substitute another interpreter.
That pin recognizes every `env`-based Node shebang, including `#!/usr/bin/env -S node --flag`, and preserves the flags; an `env` shebang naming no interpreter fails closed rather than silently falling back to `PATH`.
Its event stream must contain at least one completed turn, end with a successful `stop` assistant turn, and complete the agent before Crosscheck accepts that terminal turn's JSON verdict.
Pi credential provisioning is a captain-owned prerequisite: the selected `account_home` must contain a usable `openai-codex` OAuth entry in `auth.json`, and Firstmate does not create or copy that credential.
Because Pi selects only the default `openai-codex` slot and reviewer launches disable extension discovery, a Pi reviewer home holds exactly one account; a multi-slot Pi home reviews as its default slot, not as whichever slot has capacity.

Pi is a third client, not extra capacity.
It authenticates against the same upstream OpenAI accounts the Codex reviewer uses, so a Codex account at its usage limit is equally unavailable through Pi, and a Pi reviewer does not route around an exhausted Codex account.
What Pi adds is an independent client path and a reviewer that is separate from a Claude author by construction.
A usage-limited reviewer account records a `tool-failure`, never a verdict about code, and Crosscheck then advances to the next independent entry rather than refusing the merge.
Failover is limited to faults that prevented a verdict: a launch failure, an unusable credential, a provider that was never reached, or an exhausted account.
A reviewer that reached the model and then declined clearance, returned no valid artifact, or returned a malformed one ends the run on the spot, because that is the reviewer's own conclusion and a second account must not be used to shop for a friendlier one.
Each abandoned attempt is recorded as its own `tool-failure` run, so the ledger names every account that was tried and why it was left, and each attempt gets its own pristine exact-head checkout so no reviewer inherits an earlier reviewer's helpers or scratch state.
Selection therefore makes the gate as available as the roster rather than as available as its first entry.
Every candidate passed the configured model policy and either the ordinary mandatory account-separation screen or an exact legacy admission.
`run_reviewer` re-proves ordinary account separation against the credential it actually binds, while a legacy-admitted run re-proves only the selected reviewer's identity and preserves the explicit unproven-author label.

One upstream account routinely exists behind several directories at once, so two different `account_home` paths can execute as the same account.
Codex and Pi both authenticate against OpenAI, and a Claude config home that records no account of its own borrows whatever credential the environment supplies.
Path inequality therefore cannot establish account separation on either provider.
When the author and the reviewer resolve to the same provider, Crosscheck compares the account each home executes as and refuses a reviewer that resolves to the author's account, an unreadable identity on either side, or a credential such as an API key that names no account at all.
An identity that cannot be resolved is never separation, and the refusal happens at selection so a genuinely provable reviewer later in the list can still be chosen.
The account is read from `tokens.account_id` for Codex, `openai-codex.accountId` for Pi, and `oauthAccount.accountUuid` in `.claude.json` for Claude; `bin/fm-crosscheck.py`'s `account_identity` keys that resolution on the provider so a new client on an existing provider cannot reopen the hole.
`run_reviewer` repeats the comparison against the credential it actually binds, and that launch-time check is the authoritative one.
A lane that records no `account_home` is an ordinary supported author identity, not an emergency.
Account routing is off by design for any harness outside Codex and Claude, so a Pi lane structurally cannot record an `account_home`.
Requiring one, or an `account_routing_emergency_bypass=1` marker in its place, made every Pi-launched lane permanently unmergeable through this gate, and a bypass that has to be set on the majority of lanes is not a gate.
A different supported provider proves account separation by namespace for any account-less author.
A Pi author additionally records the exact selected provider slot in its model prefix, and `fm-spawn.sh` copies the selected Pi credential and configuration directory into restrictive task-private storage before launch.
It derives the slot's `accountId` from that private copy, records it in task metadata, and binds the actual Pi launch to the same directory through `PI_CODING_AGENT_DIR` on every spawn backend.
Same-provider eligibility requires that launch-bound recorded identity and never re-reads ambient Pi credentials as author proof; a missing snapshot fails closed unless the exact task, PR, and head carry the explicit legacy admission above.
Recovery takes a new private copy and preserves eligibility only when its identity matches the previously recorded identity exactly, while a changed account drops the recorded field instead of migrating the task's author identity.
That identity lets a same-provider reviewer prove it executes as another OpenAI account without inventing an `account_home` for the author.
A missing directory, unsafe or failed copy, malformed auth file, absent slot, or unreadable `accountId` proves nothing and leaves every same-provider reviewer ineligible.
Other account-less same-provider pairs remain ineligible because no account comparison is available.
Model identity compares the model itself, not the recorded string: Pi records `<provider-slot>/<model>`, so `openai-codex-2/gpt-5.6-sol` is the same model as a Codex reviewer's `gpt-5.6-sol`.
That canonical identity is screened out by default and is what marks a selected review as same-model when the explicit relaxation is on.
Provider is what the namespace fallback compares, not harness: Codex and Pi are both the OpenAI provider, while Anthropic is separate.
The accepted profiles are Codex `gpt-5.6-sol` xhigh, Claude `claude-opus-5` xhigh, and Pi `gpt-5.6-sol` xhigh; no allowlist change is needed to enable the existing Codex profile.
Absent reviewer configuration, unavailable credentials, model-policy mismatch, and unprovable account separation without an exact legacy admission all produce `CROSSCHECK TOOL-FAILURE` and a nonzero exit before reviewer launch.

Crosscheck requires Python 3.11 or newer and refuses to run on anything older.
This is a safety floor rather than a style preference: the bounded-read layer rejects hostile JSON integers by relying on CPython's integer/string conversion limit, which first exists in 3.11, and on an older interpreter that rejection silently stops happening while every banner the gate prints reads exactly the same.
Stock macOS `python3` is 3.9, so `bin/fm-crosscheck.sh` resolves a supported sibling interpreter instead of assuming `python3` qualifies, and `bin/fm-crosscheck.py` enforces the same minimum itself so a direct invocation cannot bypass it.
`bin/fm-crosscheck-python-lib.sh` owns that resolution for both the wrapper and the behavior tests; `FM_CROSSCHECK_PYTHON` selects an explicit interpreter and `FM_CROSSCHECK_MIN_PYTHON` overrides the minimum.
A `FM_CROSSCHECK_MIN_PYTHON` that is not `<major>.<minor>` is refused rather than parsed into a lower floor, because a bare `3` would otherwise silently admit Python 3.3.
An explicitly configured `FM_CROSSCHECK_PYTHON` that is missing or below the floor refuses by name rather than falling through to some other interpreter, so a typo or a stale path cannot silently unpin the gate.
CI pins a single modern interpreter and therefore cannot observe this class of defect on its own, which is why the floor is asserted at runtime rather than assumed from the CI matrix.

Start crosscheck as soon as a PR URL exists so it can overlap no-mistakes' remaining CI work.
The reviewer is a real policy-grade agent invocation and normally takes minutes, so Crosscheck is not a fast local check.

```sh
bin/fm-crosscheck.sh run <task-id> <https://github.com/owner/repo/pull/number>
```

The run writes `data/<task-id>/crosscheck-ledger.json` and the readable `data/<task-id>/crosscheck.md` report.
The run exits zero only when the exact head has a complete review, the reviewer supplied a successfully gate-reexecuted exact-base/exact-head reproduction, the durable ledger has no active blocker, and the reviewer returned no unreproduced suspicion.
It fetches `refs/pull/<number>/head` from the base repository into a disposable Git checkout and requires that ref to resolve to the exact live API head SHA before reviewer launch.

The reviewed base is the merge base of that head and the live base branch, resolved in the review checkout, and it is the base every downstream consumer uses: the reviewer prompt, the verdict-level execution proof, the ledger run, and verification.
It is deliberately not GitHub's `base.sha`.
GitHub reports `base.sha` as the base branch tip observed when the snapshot was taken, so on an active default branch it is usually not an ancestor of the PR head and it changes whenever anything else merges.
Treating it as the reviewed base made two failures routine: an un-rebased PR was refused before launch because the live base was not the checkout's merge base, and a ledger written minutes earlier stopped matching at the merge gate because the branch had moved for reasons unrelated to the PR.
Both refusals were artifacts of comparing a moving value, not evidence about the change, and a gate that cannot be satisfied is worse than no gate because it trains its operators to route around it.
The merge base converges instead: the default branch advancing cannot change it unless the branch absorbs commits already reachable from this head, in which case the remaining diff is a subset of what was reviewed and the review stays sound.
Any change to the PR itself - a new commit, a rebase, a force-push - changes the head SHA, which invalidates the ledger match on its own, so the head remains the pin GitHub's atomic merge enforces.
Verification therefore matches the live head and the stable claims digest, and checks the execution proof against the merge base the run recorded.
Each run records both values: `base_sha` is the reviewed merge base, and `base_branch_sha` is the base branch tip GitHub reported at snapshot time, so a ledger shows on its face when the default branch had moved ahead of the review.
The authoring worktree is not cloned, checked for cleanliness, or required to match the PR head because no verdict about the remote PR may depend on mutable author-lane filesystem state.
An empty `FM_STATE_OVERRIDE` falls back to the home state directory, so task metadata, the shared per-task lock, and the disposable review checkout cannot split across callers' current working directories.

`bin/fm-pr-merge.sh` calls the verification form automatically after approval.
Do not call the verification form as a substitute for running a reviewer.

```sh
bin/fm-crosscheck.sh verify <task-id> <https://github.com/owner/repo/pull/number>
```

Verification re-reads the live PR head and complete claims document.
It requires the latest attempt matching that head and the stable PR number/title/body claims digest to be clear, then prints only the exact reviewed SHA.
Dynamic check counts in the full `gh-axi` document remain visible to the reviewer but are excluded from the digest so CI completing in parallel does not invalidate an otherwise exact review.
The merge helper sends that SHA in GitHub's atomic expected-head merge or enqueue request.
A force-push before verification invalidates the ledger match, while a force-push after verification makes GitHub reject the expected-head merge or enqueue request.

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
A run that used the local same-model relaxation records `reviewer.model_independence` as `same-model`; older and ordinary cross-model runs omit that field.
A legacy-admitted run separately records `reviewer.author_account_independence` as `unproven-legacy-admission` plus the exact admission and reviewer-identity digests.
The readable report renders both distinctions before its summary.

- `tool-failure` means environment, task metadata, reviewer configuration, exact-head fetch, executing-account binding, or required command-execution proof prevented a trustworthy verdict.
- `cannot-certify` means a reviewer completed but the changed implementation's own test system had no trustworthy mutation-certification route the gate could execute.
- `unreviewed` means a reviewer ran but no valid exact-head verdict artifact exists.
- `blocking` means a completed reviewer with successful command-execution evidence declined clearance through a suspicion, admitted finding, or a named test that stayed green under its implementation mutation.
- `clear` means a completed reviewer with successful command-execution evidence earned clearance and no durable blocker remains.

CLI banners preserve the same distinction as `CROSSCHECK TOOL-FAILURE`, `CROSSCHECK UNREVIEWED`, and `CROSSCHECK BLOCKING`.
Only `blocking` is a review verdict about code.

New findings must supply a helper under `.crosscheck/reproductions/`, a command naming that helper, an expected exit code, and a distinctive output marker.
Crosscheck executes the command itself and stores its actual exit and bounded output in the ledger.
Every verdict artifact must also carry one verdict-level reproduction whose command names the exact base and head SHAs.
The reviewer must create and run that helper with its own command tool, and the helper must leave a receipt naming both SHAs, `HOME`, and the provider account selector.
Crosscheck inspects that receipt before independently re-executing the helper, then stores the receipt digest and bounded content with the verdict.
A missing or failed verdict-level reproduction is a `tool-failure`, so a reading-only concern from a reviewer with a dead command tool can never become a blocking code verdict.
The gate's re-execution is deliberately independent: it re-runs the helper itself in the review checkout with no network and none of the reviewer's provider credentials or account environment.
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
An approved runner is a NAME, and the gate resolves that name into an invocation rather than assuming a bare binary on `PATH`.
Before either proof run, the gate applies the mutation in a disposable inspection checkout and selects the certification system from the mutated implementation paths themselves.
A JavaScript or TypeScript mutation must resolve with its named test to one nearest tracked `package.json`, and that package's test script or dependencies must declare one unambiguous Jest or Vitest system.
A mixed JavaScript/Python mutation, a test outside the changed package, an ambiguous declaration, or a proof naming a different runner is `CANNOT-CERTIFY`, never `CLEAR`.
Python mutation behavior remains on its existing pytest route exactly as before.
This matters because every Python repository in this fleet is uv-managed: a bare `pytest` is routinely absent there, while `uv run pytest` is the invocation that works, and `python3 -m pytest` cannot be expressed in the vocabulary at all because `python3` is a file runner whose command line puts the test path before its arguments.
`pytest` therefore resolves through `uv run pytest`, then `python3 -m pytest`, then the bare binary.
Order is load-bearing: inside a uv project a bare `pytest` can exist and resolve against a different environment than the repository uses, so finding it first would run the named test under an interpreter the project never selected.
The uv rung is offered only when a uv project actually governs the named test, discovered by searching upward from that test to the checkout root, and it is passed to `uv run --project` so a monorepo service directory is selected without moving the working directory the test path is relative to.
Each rung except the last identifies itself before being trusted; the last is the plain runner name and is accepted on presence, exactly as before, so the ladder can never turn a working setup into a refusal.
Keeping the declared name is what preserves pytest's `path::selector` node-id support, which a separate runner name for module invocation would have silently dropped.
That array must be empty for a mutation proof, and any entry is refused by name.
The classified non-execution signal is a property of the runner's default exit semantics, and a supplied flag can change them: measured on pytest 9.1.1, a mutation raising during import of the named test's module exits 2 on its own but 1 under `--continue-on-collection-errors`, and 1 carries no classification, so the gate would certify a fix on a test that was never collected.
A positional argument separately adds a second target, and `test_path` is the only target the gate validates as tracked, symlink-free, and unreachable by the mutation patch, so the verdict could come from a file the gate never validated.
Requiring no arguments closes both without an enumeration of runner flags that would go stale.
Reviewer-supplied argv is only half of it: both proof runs also execute under an environment the gate constructs from `PROOF_ENVIRONMENT_ALLOWLIST` rather than the one it was launched with, because pytest appends `PYTEST_ADDOPTS` to the command line, so an operator with `--continue-on-collection-errors` exported would reproduce the same bypass on every proof with no reviewer involved.
That list is an allowlist because it fails closed - a variable that is needed but missing breaks the baseline run, which must exit 0, so the proof is refused where it can be seen, while an unlisted variable on a denylist would sail through silently.
The constructed environment is applied to the mutation-proof runs and not to reproduction re-execution: a proof's exit status is what decides clear versus not clear, whereas ambient interference with a reproduction can only push it toward refusal, and reproduction commands run through a login shell that re-imports operator profile state regardless.
Configuration files are the third channel into the same semantics: pytest's `locate_config` walks every parent of its target to the filesystem root and stops at the first `pytest.ini`, `tox.ini`, `setup.cfg`, or `pyproject.toml` it finds, so an operator config above the gate's temporary root would set `addopts` for every proof on the machine.
Crosscheck writes a neutral empty `[pytest]` `pytest.ini` into that temporary root before anything runs, ending the walk inside a directory the gate owns and neutralising every ini setting from above rather than only `addopts`.
The proof checkouts and the review checkout are both children of that root, so the one file covers reproduction re-execution as well; the boundary is the root the gate owns, not any child of it.
This is not free: for a repository carrying no pytest config of its own, rootdir becomes the gate's temporary root instead of the checkout, which widens conftest discovery by that one empty gate-owned directory.
The reviewed repository's own config still takes precedence, because it sits closer to the named test, and that surface stays deliberately accepted.
The same rule is not applied when replaying a recorded proof, so a ledger written before it still loads; instead a recorded proof whose invocation carried arguments no longer certifies its finding, which reverts to blocking and can be re-proved in band by a fresh review.
Crosscheck destroys the mutation-inspection checkout, creates a clean baseline checkout at the exact reviewed head, confirms the named test passes, destroys that entire checkout, recreates the same path from the exact head, applies the patch, and requires the same test to fail.
Destroying all readable baseline state before the mutated run prevents a test from manufacturing causality through a predictable sibling checkout.
For Jest, each clean proof checkout must begin without a package-local runner; a tracked or otherwise preexisting `node_modules/.bin/jest` is refused rather than accepted as provenance.
The gate requires exactly one tracked package lock whose root declares Jest and whose `node_modules/jest` entry binds a semantic version to the official npm registry tarball with valid sha512 integrity.
Starting from that entry, it resolves every dependency, optional dependency, and peer dependency through the lockfile's exact nested and hoisted `node_modules` paths and authenticates the complete reachable runtime closure before installation.
Every closure entry must occupy a canonical package path and bind its own name and semantic version to its exact official npm registry tarball with valid sha512 integrity.
Local, linked, workspace, Git, URL, custom-registry, missing-integrity, project-npm-configured, and currently pnpm-governed Jest routes are explicit `CANNOT-CERTIFY` outcomes.
The gate detects the project's declared Node major, selects a matching interpreter from the standard version-manager directories, and materializes dependencies afresh from that `package-lock.json` with `npm ci --offline --ignore-scripts` inside the no-network proof sandbox and empty gate-owned npm user and global configuration.
After installation, it requires every closure package to be a real non-symlink directory inside the package tree whose package name, version, and runtime dependency declarations match its authenticated lock entry.
It also requires `node_modules/.bin/jest` to resolve to the executable `bin/jest.js` inside the authenticated materialized Jest package.
The selected Node path remains bound through dependency installation and the baseline and mutated Jest runs.
A cold dependency cache, missing or ambiguous lockfile, preexisting runner, unavailable package manager or Node version, unsupported Vitest route, or invalid materialized Jest package or binary is `CANNOT-CERTIFY` and never a test verdict.
The gate invokes Jest with its own fixed `--runInBand --runTestsByPath --ci --no-cache --json` protocol and accepts a fix only when the baseline JSON reports at least one executed passing test and the mutated JSON reports at least one executed failing test.
A Jest test that executes and stays green under the mutation is durably downgraded to `claimed-fixed`, keeping the finding and the run `blocking` instead of turning inadequate coverage into an infrastructure outcome.
Proof sandboxes also omit shared POSIX IPC and give each run private writable temporary and cache state, while shared host temporary directories remain outside the write policy.
The named test must be a canonical tracked regular file; symlinks are rejected so a patch cannot mutate the executed target through an unchanged alias.
Symlink rejection is anchored at the resolved review checkout, so a symlink inside the repository is still refused while a symlinked ancestor above the firstmate home is not mistaken for one.
`test_path` may also be a `path::selector` node id for a runner that accepts one; every path-shaped check reads the part before `::` while the runner receives the full selector.
The gate positions the tracked test path itself as the interpreter script or test-framework target; generic command launchers are not approved runners.
A run that never reached the named test is not a test result in either direction.
The gate resolves the named runner to an absolute executable before launching, and treats an absent runner, a failed sandbox exec, and a runner-reported non-execution as named non-executions.
That matters in both directions: such a status must not condemn a baseline run, and must not vindicate a mutated one, because a mutation that merely broke collection would otherwise read as a caught regression.
Pytest uses the gate's measured usage and no-tests-collected exit statuses; Jest uses positive machine-readable executed-test counts instead of inferring execution from its exit code.
Every other runner remains unable to certify until it has its own positive or measured non-execution protocol.
The proof checkout starts as a fresh clone carrying tracked files only, and any language environment it needs must be reconstructed through the bounded routes above.
The patch may modify only non-test implementation paths already cited by the durable finding.
It cannot modify the named test, conventional test trees, fixtures, or Crosscheck evidence support.

### Known Python limitation: the mutated pytest exit status is an inference, not proof

The Jest route uses positive JSON execution counts and does not share this limitation.
Read the four Python guards above together and the shape of the remaining problem is visible.
The pytest route concludes "the named test detected the regression" from one fact: the mutated run exited non-zero.
That status is not a property of the test alone. It is influenced by reviewer-supplied argv, by the ambient environment, by repository and ancestor configuration, and by the runner's own version, and each of those four channels was closed only after it was found - a positional second target, a collection-error flag, `PYTEST_ADDOPTS`, and an ancestor ini file.
An installed runner plugin is a known and accepted fifth door.
Closing channels one at a time is unbounded work with no completion criterion, so the list above should be read as hardening, not as a proof of soundness.

The planned replacement is POSITIVE PROOF OF EXECUTION: requiring the mutated run to demonstrate that the named test actually ran, rather than inferring it from an exit code.
The leading candidate is a control test - a second tracked test the mutation should not affect, required to PASS while the named test fails - because it needs no per-runner knowledge and no enumeration of the ways a status can be rewritten.
Until that lands, the pytest exit-status inference remains this gate's weakest link, and the four closed channels do not make it sound.

## Refusal and liveness

The reviewer is a synchronous Codex or Claude agent invocation with a bounded timeout and a JSON output schema.
Normal runs take minutes and callers should budget them as remote agent work rather than a cheap local preflight.
PR claims are delimited as untrusted data, and the reviewer is directed to ignore embedded instructions and use focused evidence rather than duplicate no-mistakes' broad suite.
Later reviewers receive only a bounded projection of finding IDs, lifecycle state, severity, exact-head clearance, and proof digests.
Finding prose, reproduction output, test output, and lifecycle notes remain durable in the ledger but are never reinjected into a later reviewer prompt.
The Codex path pins `gpt-5.6-sol`, xhigh reasoning, noninteractive approval, an independent `CODEX_HOME`, the same account-bound `HOME`, and the exact review checkout.
The Claude path pins `claude-opus-5`, xhigh effort, the installed unattended `--dangerously-skip-permissions` mode, a Bash-required bounded tool list, no session persistence, an independent `CLAUDE_CONFIG_DIR`, the same `CLAUDE_SECURESTORAGE_CONFIG_DIR`, a disposable private `HOME`, and structured JSON output.
That private `HOME` maps `.claude` and `.claude.json` to the selected reviewer account directory, so Claude's hard-coded `~/.claude/session-env` writes land in per-account state rather than shared operator state.
It also maps the current user's Keychain directory, derives Claude's exact scoped service from the selected account directory, and verifies the non-secret service metadata before reviewer launch.
That mapping is unconditional on macOS, not a fallback for accounts that lack an OAuth file.
macOS resolves a Keychain search through `$HOME/Library/Keychains`, so under a private `HOME` an unmapped Keychain is simply unreachable, and a real account directory routinely holds both a live scoped Keychain item and a stale `.credentials.json` left beside it.
Mapping the Keychain only when `.credentials.json` was absent therefore sent every such reviewer to the stale file, where it failed with `Failed to authenticate: OAuth session expired and could not be refreshed` in one turn, with no tokens and no API time, while the same account worked normally outside the gate.
The scoped Keychain item is preferred when it exists, because it is the credential the launched reviewer actually executes as; a regular non-symlink `.credentials.json` remains the recorded source only when no scoped item is present.
This is a binding inside the reviewer's own private `HOME`, not a sandbox grant: the generated profile is unchanged, and reads of the operator's Keychain directory were already permitted by it.
Because Claude's unattended mode disables its own permission prompts, Crosscheck places the process under the installed macOS `sandbox-exec` contract: reads, process execution, and provider network access remain available, while writes are limited to the disposable review checkout, the selected per-account reviewer directory, and `/dev/null`.
The profile never grants the ambient operator `~/.claude` tree or its session scratch subtree.
Claude's Bash engine otherwise creates workspace scratch under shared `/tmp/claude-<uid>` independently of ordinary `TMPDIR`.
Crosscheck sets the supported `CLAUDE_CODE_TMPDIR` to a private directory inside the disposable checkout, keeping that scratch under the existing checkout write boundary instead of widening the sandbox to shared `/tmp`.
It does not grant write access to the author worktree or the wider filesystem.
An unavailable reviewer binary, sandbox, author-identity proof, executing-account binding, verdict-level execution proof, or exact remote PR head records a `tool-failure` attempt when the live head is already known, and otherwise emits the same tool-failure class without fabricating a ledger run.
A ledger that cannot be read is the one stop that cannot record itself: appending a run to a file that failed to parse would risk destroying the durable findings it still holds, so the ledger is left exactly as it is and only the readable `crosscheck.md` report is rewritten, naming the parse failure so the cause is on disk rather than only in the exit status of a run nobody kept.
A reviewer that never reached its provider is also a `tool-failure` rather than an `unreviewed` attempt, and is the case that fails over.
The two are distinguished by evidence of model work: a Claude result envelope with no API duration, no token usage, and no per-model usage, or a Codex exit that wrote no result artifact at all, means the account never spoke and the gate learned nothing about the code.
Recording that as `unreviewed` also manufactured a suspicion in the ledger, which reads like the reviewer raised a concern about the change when it had not started.
Failure banners quote what the reviewer actually reported - for Claude the envelope's `result`, `subtype`, `terminal_reason`, `api_error_status`, and any permission denials, plus captured stderr - rather than a fixed-length excerpt of the raw envelope, because the sentence that explains a failure sits past the point such an excerpt stops.
A timeout, or a reviewer that reached the model and then produced a missing, empty, malformed, or wrong-head artifact, records an `unreviewed` attempt and exits nonzero.
A completed review whose changed implementation has no executable mutation-certification route records `cannot-certify`, names the exact missing route, and exits nonzero without fabricating either a code verdict or a pass.
An unresolved suspicion comes from a completed reviewer and records a `blocking` attempt instead of being conflated with an invalid review artifact.
This includes provider refusals that surface only as a stopped or silent agent.
`bin/fm-crosscheck.sh` refuses earlier than any of these when it cannot resolve a Python 3.11 or newer interpreter for `fm-crosscheck.py`: it prints a `CROSSCHECK UNREVIEWED` banner naming the requested and discovered versions, exits nonzero, and records no ledger run because nothing about the PR was examined.
That fail-closed banner keeps an interpreter defect from reading as a clear review; interpreter discovery order and the `FM_CROSSCHECK_PYTHON` override are owned by [configuration.md](configuration.md#toolchain).
Reviewer stdout plus stderr use a separate 16 MiB capture ceiling because a full agent transcript routinely exceeds the ordinary command budget.
`FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES` can override that ceiling between 200,000 bytes and 64 MiB, and an invalid value fails closed before reviewer launch.
This remains a hard bound rather than truncation: Claude returns its structured verdict in the captured JSON envelope, while Codex must still provide its separate authoritative result artifact.
Crossing the reviewer ceiling terminates the owned process tree and records a loud `unreviewed` attempt, and captured output alone never substitutes for a valid verdict.
Evidence and every other ordinary command retain the 200,000-byte aggregate stdout-plus-stderr ceiling, except the post-review checkout integrity inspection described above, which carries its own 4 MiB budget.
The final wait and identity-pinned descendant cleanup remain inside the same absolute deadline.
Structured verdict artifacts are stable regular files bounded by the ordinary 200,000-byte ceiling before JSON decoding.
The durable ledger is bounded separately and fails closed when absent, symlinked, malformed, non-finite, or oversized.
The platform-specific containment limits and empirical mutation evidence are recorded in [crosscheck-bounded-io.md](crosscheck-bounded-io.md).
Reviewer result arrays are capped at 32 entries, at most 32 evidence executions are accepted, and all reproduction and mutation work shares a 900-second aggregate deadline by default.

## Installed external contracts

The external surface was observed on 2026-08-02 before implementation, rechecked on 2026-08-03 for nonempty TOON arrays, re-run against installed `gh-axi 0.1.25` on 2026-08-04, and extended with read-only merge-queue checks on 2026-08-08.
The 2026-08-04 recheck observed `gh-axi 0.1.25`, `codex-cli 0.146.0-alpha.9.2`, and Claude Code 2.1.221; the original Claude contract was first exercised on 2.1.220.

`gh-axi pr view` supports `--full` but does not support raw-gh `--json` or `-q` flags.
The production adapter therefore uses these exact forms.

```sh
gh-axi api /repos/<owner>/<repo>/pulls/<number>
gh-axi pr view <number> --repo <owner>/<repo> --full
gh-axi api /repos/<owner>/<repo>/rules/branches/<url-encoded-base-ref>
gh-axi api POST /graphql --field query=<query-or-mutation>
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
The read adapter exposes no merge subcommand; only the gate-refused `fm-crosscheck.sh merge` boundary can reach its private exact-SHA merge or enqueue primitives, and that boundary freshly verifies the ledger before issuing the request.

The installed reviewer invocation was exercised successfully with `--output-schema`, `--output-last-message`, `--model gpt-5.6-sol`, and `model_reasoning_effort="xhigh"` before production code used those flags.
The installed Claude invocation was exercised successfully with a private `HOME`, selected-account `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `--model claude-opus-5`, `--effort xhigh`, `--dangerously-skip-permissions`, `--tools Bash,Read,Glob,Grep`, `--no-session-persistence`, `--output-format json`, and `--json-schema` before production code used those flags.
The installed `/usr/bin/sandbox-exec` was also exercised with the generated profile: a write inside the allowed review directory succeeded, while sibling and `/private/tmp` writes failed with `Operation not permitted`.
On 2026-08-09 the Jest mutation route was exercised at relvino PR 1049 head `5649c234b0f258cde4d62870759e353fade5ff3d` in a fresh exact-head clone.
The gate selected Node 20.20.2 for the package's `20.x` declaration, used npm 10.8.2 and the tracked package lock to materialize Jest 29.7.0 offline with lifecycle scripts disabled, and ran the fixed `--runInBand --runTestsByPath --ci --no-cache --json` protocol under the no-network sandbox.
The tracked `V3PreviewPane.test.tsx` reported 33 executed and zero failed tests at baseline; replacing the session key with one shared key reported the same 33 executed tests with two failures, so the result demonstrated positive mutation detection rather than a runner-status inference.

## Validation evidence boundaries

`tests/fm-github-pr.test.sh` is hermetic coverage using checked-in TOON shapes.
The versioned fixtures it uses were observed from installed `gh-axi 0.1.25`.
Most of `tests/fm-crosscheck.test.sh` is hermetic coverage using observed-shape GitHub, Codex, Claude, and sandbox fakes.
Its `test_installed_sandbox_denies_shared_private_tmp` case is the exception: it invokes the real installed `/usr/bin/sandbox-exec` and verifies the generated proof profile denies shared host temporary state.
Its tracked `test_real_claude_sandbox_executes_exact_sha_git_diff` case is an opt-in real-runtime guard: with `FM_TEST_REAL_CLAUDE_SANDBOX_GIT_DIFF=1` and `FM_TEST_REAL_CLAUDE_CONFIG_DIR` set to a credentialed independent Claude home, it creates the same private execution `HOME`, verifies the selected OAuth-file or scoped-Keychain source, launches installed Claude under the generated installed sandbox, requires Bash to execute `git diff` between two real exact SHAs, checks the selected config paths and isolated `CLAUDE_CODE_TMPDIR`, and rejects any profile grant for the ambient operator `~/.claude/session-env`.
Ordinary CI prints a named skip for this network- and credential-dependent guard instead of substituting fake-only coverage.
The retained live runtime proof is the change receipt for this patch; the opt-in test is the repeatable regression guard for future environments.
Its `test_pytest_runner_resolves_through_a_uv_aware_ladder` case is the named regression for runner-name resolution: it pins monorepo uv-project discovery, the skipped uv rung outside a project, the unchanged absent-runner refusal, and pytest's retained node-id support.
Its `test_account_less_known_provider_lane_is_reviewable` case is the named regression for an account-less Pi lane whose provider-slot identity is unreadable: it requires a cross-provider reviewer to clear it and a same-provider reviewer to remain refused.
Its `test_same_model_relaxation_requires_proven_separate_account` case provides a launch-recorded routed Pi identity and proves that default and explicit-off policy reject same-provider review, opt-in still rejects missing, same, or unreadable account proof, ambient credential drift cannot replace the snapshot, and only a recorded-distinct OpenAI account becomes eligible.
Its `test_legacy_author_admission_is_exact_and_explicit` case proves that absent and stale admissions fail closed, replacement-unavailable acknowledgement is mandatory, a matching entry never synthesizes author identity, a modern snapshot cannot be downgraded, and an admitted reviewer still needs a readable executing account.
Its `test_legacy_author_admission_is_visible_in_prompt_and_evidence` case proves that the weaker mode is explicit in the adversarial prompt, ledger, and readable report, including both same-model and unproven-author labels.
Its `test_typescript_jest_mutation_proof_can_clear` and `test_inadequate_typescript_jest_coverage_stays_blocking` cases prove that package-governed Jest coverage can certify a TypeScript fix while a named Jest test that stays green under mutation keeps the finding blocking.
Its `test_preexisting_jest_runner_cannot_certify` case proves that a committed Jest-shaped output script is refused before package-manager materialization, and `test_local_fake_jest_package_cannot_certify` proves a lockfile-routed local fake package cannot substitute for official registry provenance.
Its `test_local_transitive_jest_package_cannot_certify` case keeps top-level Jest registry-authenticated while substituting a local `jest-cli`, and proves that every transitive runtime package must remain inside the authenticated closure.
Its `test_jest_runs_under_declared_node_major` case proves the selected Node path governs installation and both proof executions.
Its `test_typescript_without_usable_route_is_cannot_certify` case proves that an unsupported package-governed route writes and reports `CANNOT-CERTIFY` rather than silently clearing or manufacturing a code verdict.
Its `test_python_mutation_proof_is_byte_exact` case compares the complete normalized Python proof record to the pre-Jest shape so the new language route cannot drift existing pytest evidence.
Its `test_claude_execution_home_always_binds_the_keychain` case is the named regression for the private-`HOME` Keychain bind, and it fails if the bind is made conditional on `.credentials.json` again.
Its `test_moved_default_branch_stays_reviewable` case is the named regression for base drift: it advances the fake default branch past the PR's branch point, then requires the run to review against the merge base, record it, and still verify.
Its `test_unavailable_reviewer_fails_over_to_the_next_account` case covers reviewer failover using the observed zero-turn Claude error envelope, and asserts the ledger records the abandoned attempt with the reason the reviewer reported rather than a truncated envelope.
Its `test_forged_git_diff_mutation_command_is_rejected` case is the named regression that fails if a free-form `git diff --quiet # tests/regression.test.sh` can replace real mutation verification.
Its `test_baseline_readable_state_is_destroyed_before_mutation` and `test_mutation_is_bound_to_cited_non_test_implementation` cases cover the two mutation-causality bypasses found in the final review round.
Its `test_mutated_non_execution_cannot_clear_a_finding` case covers the third bypass of that class: a mutation that only broke test collection exits nonzero and previously read as a caught regression, so the gate could certify a fix on a test that never ran.
Its `test_evidence_capture_runs_on_older_interpreters` case exists because `fm-crosscheck.sh` execs whichever `python3` is first on `PATH`, which is not always the version CI pins.
A newer-only API on the evidence path therefore surfaces as an uncaught `TypeError` inside evidence capture rather than a gate verdict; the [`firstmate-coding-guidelines`](../.agents/skills/firstmate-coding-guidelines/SKILL.md) skill owns which `stat` form `bin/*.py` must use.
`tests/fm-github-pr.test.sh` includes named cases for fieldless-array grammar, complete timeout-child cleanup, and refusal of the former public merge subcommand.
The focused PR-check cases in `tests/fm-teardown-suite.sh` and the merge cases in `tests/fm-pr-merge.test.sh` also use observed-shape GitHub fakes.
Those deterministic suites validate parsing, lifecycle, failure handling, and atomic request construction; they do not claim to exercise live provider availability.
The real installed-tool exercise is separate and network-dependent: the dated `gh-axi` observations above cover successful documents, while an adapter lookup for an absent PR through installed `gh-axi` must exit nonzero with `GitHub state is unreviewed`.

The 2026-08-08 merge-queue proof deliberately stopped at the authorization boundary.
Live read-only production code invoked `GET /repos/Ruby-Labs/relvino/rules/branches/main`, received one applicable `merge_queue` rule with `SQUASH`, and returned `True`.
Live GraphQL introspection showed `EnqueuePullRequestInput.expectedHeadOid`.
Deterministic tests proved exact-head mutation construction, `enqueued/unconfirmed` rendering, and an independent open readback.
No live enqueue mutation was sent, so live mutation acceptance, live `gh-axi` `mergeQueueEntry` rendering, post-acceptance readback, and the complete live enqueue flow remain unproven.
A real product PR was not used as a test, no pre-authorized disposable queue repository existed, and the legacy enqueue fixture lacks durable live provenance, so none of those sources is end-to-end proof.

## Deliberate limitations

When the caller omits an explicit method, the merge helper uses an applicable base-branch merge queue; queue requests do not accept commit title or body fields.
Otherwise Crosscheck supports immediate `merge`, `squash`, and `rebase` methods plus commit title and body fields.
It rejects `--auto` because that path is neither the atomic expected-head REST merge nor the expected-head GraphQL enqueue.
It rejects `--delete-branch` because branch deletion is not part of the atomic merge or enqueue operation.
Delete a branch only in a later separately authorized action after the merge is confirmed.

Reviewer-generated commands execute in a non-login shell, so evidence never depends on the operator's shell profile.
This is not a detail: a login shell runs macOS `path_helper`, which rebuilds `PATH` with `/usr/bin` ahead of everything else, so a bare `python3` in a reproduction resolved to Xcode's Python 3.9 even while the gate itself ran on 3.14.
Any reproduction against a repository requiring 3.10 or newer then died on an unrelated `ImportError`, and because a failed new-finding reproduction voids the run, a complete review with real findings was recorded as `unreviewed`.
Approved mutation-proof runners are resolved from the gate's own `PATH` and were never affected.

Reviewer-generated commands execute in disposable exact-head clones with bounded timeouts.
Codex uses its installed workspace-write sandbox, and Claude uses the explicit macOS profile described above.
Both permit test processes and provider network access, so this is containment for accidental or prompt-directed file mutation, not a guarantee that hostile repository code is safe to execute.
