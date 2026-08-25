# Crosscheck

Crosscheck is an independent exact-head finding ledger at the PR merge gate.
It is not a second implementation of tests, lint, documentation checks, pushing, PR creation, or CI.
No-mistakes remains the owner of that validation pipeline.

By default, the review portion is intentionally close to "no-mistakes review with a fresh, different model."
Most of its review-quality value comes from that cross-model independence.
Review independence is structural: Crosscheck and no-mistakes use different models from separate account pools, and Crosscheck runs separately from the lane that authored the work.
The gate does not read, infer, compare, warn on, or require author-account identity metadata because that bookkeeping only restated the architecture and turned failed capture into a false merge blocker.
The separate mechanism earns its keep only through four contracts that no-mistakes does not currently own: durable finding lifecycle across runs, gate-executed reproduction evidence, gate-executed mutation proof for fixes, and an exact reviewed SHA passed atomically to GitHub at merge.
If those contracts move into no-mistakes, the separate reviewer runner should be removed rather than defended as a parallel product.

## Operator flow

Configure one or more policy-grade reviewer accounts per firstmate home.
The file is local and gitignored at `config/crosscheck-reviewer.json`.

```json
{
  "reviewers": [
    {
      "harness": "pi",
      "model": "accounts/fireworks/models/glm-5p2",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/the/cross-family/pi/agent/home"
    },
    {
      "harness": "codex",
      "model": "gpt-5.6-sol",
      "effort": "xhigh",
      "account_home": "/absolute/path/to/an/independent/codex/home"
    }
  ]
}
```

Crosscheck resolves configured reviewer homes in order and keeps entries that satisfy its reviewer-profile and model policies.
A registered cross-family lane is the primary review family (R6, docs/azure-requirements.md).
`bin/fm-crosscheck.py` carries `CROSS_FAMILY_LANES`, a code-side registry of vetted reviewer lanes.
Each entry pins a model selector, a Pi provider slot, the chat-completions api surface, the endpoint host, the one accepted base URL, and the exact model-level `compat` the credential may carry.
Today's registry is the single lane `fireworks-glm` using the regular Fireworks GLM 5.2 selector `accounts/fireworks/models/glm-5p2`.
The roster picks the serving lane by naming that exact selector, so substituting among registered lanes is a config change.
Admitting a new endpoint stays a reviewed code change because the allowlist is the control.
The former Fast selector `accounts/fireworks/routers/glm-5p2-fast` remains readable only in historical ledgers and is refused for every new roster entry.
Each lane's credential is an api-key `models.json` in a dedicated Pi agent dir declaring exactly that lane's provider slot - never a codex `auth.json`, and never a second provider.
Each lane's endpoint is an allowlist of exactly its registered base URL, today `https://api.fireworks.ai/inference/v1` (chat completions only; any other baseUrl, including a Responses API surface, is refused by name), and the recorded reviewer identity binds the provider slot + host + model - never the api key or anything derived from it.
`compat` is the other model-level object Pi honors, so the lane pins `supportsStrictMode: true`, `sendSessionAffinityHeaders: true`, and `sessionAffinityFormat: openai` exactly.
The declared regular-lane rates are 1.40 dollars per million input tokens, 0.14 dollars per million cached input tokens, and 4.40 dollars per million output tokens.
The declaration tracks Fireworks serverless pricing at https://docs.fireworks.ai/serverless/pricing.
Fireworks publishes no separate cache-write price, so emitted cache-write tokens are charged at the uncached input rate of 1.40 dollars per million rather than silently treated as free.
A truncated reviewer turn is a failed review, never a verdict.
The strict verdict tool is the primary submission path, and the terminal assistant turn must stop with `toolUse` after exactly one call.
Pi's provider-generation schema makes nullable structured finding-update fields optional and non-null so Pi can prepare its supported strict subset.
The host restores omitted nullable fields to explicit null before applying the unchanged full review validation.
The host still validates the complete outer review schema and every evidence contract after constrained sampling.
The stringified tool-argument compatibility recovery accepts only exactly one complete top-level object and refuses unterminated fences, additional objects, ambiguous JSON-bearing remainder, malformed JSON, and non-objects.
Because pi's provider composer gives model-level `baseUrl`/`api` fields precedence over the provider level, the allowlist also refuses any model entry carrying either field - the pinned provider level must own both, even when an override repeats the pinned values.
The pi-codex/codex `gpt-5.6-sol` profiles remain only as the dormant fallback family: a run they serve prints a loud `CROSSCHECK DEGRADED` warning naming whether the `crosscheck-same-model` relaxation was required, and its ledger reviewer record carries `review_family_mode: codex-fallback` (cross-family runs record `cross-family-primary`; durable ledgers written before the registry landed carry the legacy `glm-primary`, which stays bound to exactly that lane's model) with the readable report labeling the run `CODEX FALLBACK`.
Firstmate authors also run on codex-family models, so the fallback usually needs that recorded same-model degraded state.
Claude is never an eligible Crosscheck reviewer; the interim claude lane is retired, and a claude profile is refused with the exact-profile message before any reviewer machinery runs.
Model separation is mandatory by default.
The optional local `config/crosscheck-same-model` file relaxes only that model screen when it contains exactly `on`; an absent file or exactly `off` preserves the default, and any other value or unsafe file shape is refused.
This setting is local and gitignored, is read fresh for each reviewer selection, and is not inferred from the reviewer roster or environment.
A selected same-model reviewer receives a visible reduced-independence prompt that directs it to attack the change adversarially, falsify the author's claims instead of confirming them, and report a finding when uncertain.
Its ledger reviewer record carries `model_independence: same-model`, and the readable report labels the run `SAME-MODEL` so the reduced model independence cannot be mistaken for a cross-model review.

The reviewer `account_home` remains mandatory because it binds the reviewer launch to the dedicated Crosscheck account pool.
It is not compared with task metadata and does not establish an author-account identity claim.
Missing or failed Pi author-account capture therefore has no effect on reviewer selection, review admissibility, the durable verdict, or merge verification.
The former `config/crosscheck-legacy-author-admissions.json` path existed only to work around the removed author-identity refusal and is no longer read.

Crosscheck then binds the provider's executing credential selector to that exact reviewer path and requires the verdict plus a local reviewer's Bash-created receipt to report the selector and actual private `HOME`.
For Azure reviews, the controller binds the model compartment identity independently, while the later credentialless tool and verifier receipts bind only their distinctive marker and the exact base and head SHAs.
For Pi, the terminal event must also report the exact provider slot and model selector that the roster requested.
A run that reports the historical Fast selector, another provider, or no model identity is a tool failure rather than a regular-lane verdict.
That proves which dedicated reviewer home executed the review without comparing it to an author account.
Every reviewer disables reviewed-repository instruction discovery at launch: Codex sets `project_doc_max_bytes=0`, and Pi uses `--no-context-files`.
Pi is launched through the resolved installed executable at `xhigh` with JSON event output, offline startup, an ephemeral session, and only the read and Bash-capable review tools plus the explicit verdict tool.
The prompt is passed by `@file` so repository and claim size cannot exceed the process argument limit.
Extension discovery remains disabled while the tracked verdict extension is loaded explicitly.
That extension registers a strict JSON-schema-constrained `submit_crosscheck_verdict` tool whose successful execution terminates that attempt without another model turn.
The local regular GLM lane runs a fixed two-pass full-diff protocol: an isolated advisory challenge followed by an authoritative synthesis that independently inspects the same exact-base/exact-head diff and receives only a bounded projection of the challenge's untrusted hypotheses.
Only the synthesis supplies the ledger verdict, and it must reproduce any challenge concern it carries forward rather than treating the challenge as execution proof.
The two passes never wait or sleep to affect timing, and Crosscheck aggregates their token, cost, turn, and reviewer-latency telemetry without inventing unavailable values.
The regular-lane reviewer record binds `review_depth_passes: "2"`, `review_depth_mode: two-pass-independent-synthesis-v1`, and the terminal provider/model readback to the registered regular cross-family lane.
Successful current-contract `clear` and `blocking` records, including reusable records, fail validation when any of those fields is missing or contradictory.
Failed `tool-failure`, `unreviewed`, and `cannot-certify` attempts may omit terminal and depth evidence they never earned, so their ledgers remain reloadable for a later retry; they are never reusable.
Crosscheck accepts exactly one verdict tool call from each successful pass and preserves usage across Pi auto-retries.
If an otherwise completed pass makes zero, multiple, or malformed verdict calls, the same isolated reviewer session receives one fixed verdict-only repair prompt and retains the exact-head packet plus that pass's reasoning without repeating the review.
The repair is attempted once per pass, its usage is included in the run economics, and a second protocol miss fails closed instead of selecting a convenient call or rotating to another reviewer.
Provider terminal-error diagnostics are whitespace-normalized, stripped of non-printable characters, and limited to 512 characters before they reach operator-visible failure output.
The model decides the provider slot through an explicit mapping derived from the lane registry that maps each registered model to its own slot, maps `gpt-5.6-sol` to `openai-codex`, and refuses an unmapped model rather than guessing.
For the installed npm entrypoint, Crosscheck also resolves Pi's sibling Node runtime before launch instead of allowing the reviewer environment's `PATH` to substitute another interpreter.
That pin recognizes every `env`-based Node shebang, including `#!/usr/bin/env -S node --flag`, and preserves the flags; an `env` shebang naming no interpreter fails closed rather than silently falling back to `PATH`.
Its event stream must contain at least one completed turn, end with a successful `toolUse` assistant turn, and complete the agent before Crosscheck accepts the single submitted verdict.
Pi credential provisioning is a captain-owned prerequisite, and its shape depends on the lane: a codex-family fallback home must contain a usable `openai-codex` OAuth entry in `auth.json`, while a cross-family lane home must instead contain an api-key `models.json` declaring exactly that lane's provider slot and no `auth.json` is required. Firstmate does not create or copy either credential.
Because reviewer launches disable extension discovery, a Pi reviewer home holds exactly one account and exactly one provider; a multi-provider Pi home is refused for a cross-family lane and reviews as its default slot for the codex fallback, not as whichever slot has capacity.

Pi on the codex-family fallback is a third client, not extra capacity.
On that lane it authenticates against the same upstream OpenAI accounts the Codex reviewer uses, so a Codex account at its usage limit is equally unavailable through Pi, and a Pi reviewer does not route around an exhausted Codex account. A cross-family lane is a different provider entirely and shares none of that capacity.
What Pi adds is an independent client path and a reviewer that is separate from a Claude author by construction.
A usage-limited reviewer account records a `tool-failure`, never a verdict about code, and Crosscheck then advances to the next independent entry rather than refusing the merge.
Failover is limited to faults that prevented a verdict: a launch failure, an unusable credential, a provider that was never reached, or an exhausted account.
A reviewer that reached the model and then declined clearance, or still returned no valid artifact after the one bounded protocol repair, ends the run on the spot because a second account must not be used to shop for a friendlier conclusion.
Each abandoned attempt is recorded as its own `tool-failure` run, so the ledger names every account that was tried and why it was left, and each attempt gets its own pristine exact-head checkout so no reviewer inherits an earlier reviewer's helpers or scratch state.
Selection therefore makes the gate as available as the roster rather than as available as its first entry.
Every candidate passed the configured reviewer-profile and model policy.
Reviewer credential inspection still proves that the selected reviewer home can execute its configured client, but it makes no claim about the author.
Model identity compares the model itself, not the recorded string: Pi records `<provider-slot>/<model>`, so `openai-codex-2/gpt-5.6-sol` is the same model as a Codex reviewer's plain `gpt-5.6-sol`.
That canonical identity is screened out by default and is what marks a selected review as same-model when the explicit relaxation is on.
The accepted profiles are Pi at xhigh on every registered cross-family model selector (today `accounts/fireworks/models/glm-5p2`) as the primary family, plus Codex `gpt-5.6-sol` xhigh and Pi `gpt-5.6-sol` xhigh as the loud degraded fallback family.
Reviewer independence is compared on the model FAMILY, not the exact id, so a `gpt-5.5` author is not admitted a `gpt-5.6-sol` reviewer (finding cc-4dcd7873f71a); an unrecognized model remains its own family.
Absent reviewer configuration, unavailable reviewer credentials, or model-policy mismatch produces `CROSSCHECK TOOL-FAILURE` and a nonzero exit before reviewer launch.

The lock-free status read reports whether the roster's first serving family is the cross-family primary or the Codex fallback, the current `crosscheck-same-model` setting, and the latest durable run's `review_family_mode` when a run exists.

```sh
bin/fm-crosscheck.sh status
```

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

New run records carry additive telemetry for input, output, cache-read, and cache-write tokens when Pi reports them.
The record keeps provider-reported cost, Pi-calculated cost, and cost recomputed from the pinned declared rates as separate fields with explicit provenance.
Pi events do not currently expose a provider-reported billing value, so that field remains null instead of relabeling Pi's calculated value.
The same record carries completed turns, reviewer latency, outcome, normalized failure category, finding disposition, and optional reuse provenance; regular-lane totals aggregate both full-diff passes.
Use `bin/fm-crosscheck.sh economics <task-id>` for a read-only per-run table and totals.

Crosscheck can reuse an already accepted original review without another provider request only when the exact head SHA, reviewed base, stable claims digest, reviewer credential identity, and byte-derived review-contract digest are unchanged.
It never reuses a blocking, unreviewed, tool-failure, cannot-certify, suspicious, or already reused run.
The new run remains in state `clear` and records the exact SHA-256 digest of its source run under telemetry reuse provenance.
Merge verification resolves that exact earlier source and revalidates its execution proof, reviewer identity, contract digest, and Azure compartment identity when applicable.
Missing, changed, ambiguous, or chained source provenance fails closed.

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

### Recorded phase durations

Every run record carries `durations_ms`, an integer millisecond breakdown of where that invocation's wall clock went (C1, `docs/azure-requirements.md`).
The local lane records `snapshot` (task metadata, the GitHub head/claims lookup, reviewer selection, and the exact-head review checkout), `reviewer` (the bounded reviewer subprocess), `proofs` (the reproduction and mutation verification the gate re-executes for itself), `ledger` (reading and validating the durable ledger plus this invocation's earlier writes), and `total`.
The Azure compartment lane additionally records `create`, `stage`, `boot`, and `collect` after its completed Azure identity binds those phases to that lane.

Every recorded phase represents work the run actually entered, but a failed compartment attempt may omit lane-only detail it cannot bind.
An absent ordinary phase means the run never entered it, so a run that failed before reviewer launch records no `reviewer` key rather than `reviewer: 0`.
A failed compartment attempt has no complete Azure identity to bind lane-only detail, so the writer omits `create`, `stage`, `boot`, and `collect` from that run while retaining `total` and compatible ordinary phases.
The difference remains real unattributed time rather than a fabricated zero.
Durations are measured on `time.monotonic()`, so a clock change cannot move them, while the record's `at` stamp remains the wall clock it has always been.
Phases never nest and named phases round down while `total` rounds up, so `total >= sum(named phases)` holds exactly; the difference is real unattributed time between phases, not rounding.
Two reviewer attempts inside one invocation accumulate into one `reviewer` phase, because the invocation really did spend both.
The one cost `total` does not include is the final write that lands the record: a record cannot contain the duration of writing itself, which makes `total` a floor rather than an inflated estimate.

The readable report and the run's own output each name the total and the largest phases on one line.
The full table is a read-only subcommand that takes no lock and changes nothing:

```sh
bin/fm-crosscheck.sh timings <task-id>
```

```
at                    family          state         snapshot  reviewer  proofs  ledger  create  stage  boot  collect  total
2026-08-02T00:00:00Z  -               tool-failure  -         -         -       -       -       -      -     -        -
2026-08-20T13:49:06Z  codex-fallback  clear         1217      539       479     0       -       -      -     -        2525
```

Rows are per run record, not per invocation, and their totals can overlap.
One invocation that fails over to a second reviewer writes two rows: the first records the invocation up to that failure, and the second records the whole invocation including it.
Summing the `total` column therefore double counts; read the last row of an invocation for its duration, not the column sum.

`durations_ms` is additive.
A run recorded before this field existed still validates and still renders, and shows `-` in every phase column rather than a fabricated zero.
A record that does carry one is held to the full contract: integers only, never negative, only phase names the gate defines, a `snapshot` phase (every run that reaches a record has performed it), and a `total` that covers the phases it names.
The compartment phases are lane-bound rather than writer-asserted: `create`, `stage`, `boot`, and `collect` are admitted only on a record whose own reviewer entry carries `execution_mode: azure-compartment-v1`; a failed attempt without that completed identity retains its total but cannot claim the lane-only breakdown.
A run's `at` stamp is pinned to `YYYY-MM-DDTHH:MM:SSZ` for the same reason: it is the one free-form string the table renders, and an embedded newline would let one record forge extra rows.

The writer removes compartment-only phases from a run that lacks a completed compartment identity, then validates the compatible measurement against that same contract before writing it.
Everything that later reads this ledger validates it, so an unvalidated write would be a durable outage: one writer bug and `run`, `verify` and `timings` all refuse the task until a human edits the JSON by hand.
Any other timing-contract bug still loudly costs one run its breakdown and never the durable findings.

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
The readable report renders that distinction before its summary.

- `tool-failure` means environment, task metadata, reviewer configuration, exact-head fetch, reviewer credential binding, or required command-execution proof prevented a trustworthy verdict.
- `cannot-certify` means a reviewer completed but the changed implementation's own test system had no trustworthy mutation-certification route the gate could execute.
- `unreviewed` means a reviewer ran but no valid exact-head verdict artifact exists.
- `blocking` means a completed reviewer with successful command-execution evidence declined clearance through a suspicion, admitted finding, or a named test that stayed green under its implementation mutation.
- `clear` means a completed reviewer with successful command-execution evidence earned clearance and no durable blocker remains.

CLI banners preserve the same distinction as `CROSSCHECK TOOL-FAILURE`, `CROSSCHECK UNREVIEWED`, and `CROSSCHECK BLOCKING`.
Only `blocking` is a review verdict about code.

New findings must supply a helper under `.crosscheck/reproductions/`, a command naming that helper, an expected exit code, and a distinctive output marker.
Crosscheck executes the command itself and stores its actual exit and bounded output in the ledger.
Every verdict artifact must also carry one verdict-level reproduction whose command names the exact base and head SHAs.
The local reviewer must create and run that helper with its own command tool, and the helper must leave a receipt naming both SHAs, `HOME`, and the provider account selector.
In Azure static-packet mode, the model proposes the helper and the controller runs it in separate credentialless tool and verifier VMs, so that remote receipt proves its marker and both exact SHAs without pretending to observe the model compartment's private paths.
Crosscheck inspects that receipt before independently re-executing the helper, then stores the receipt digest and bounded content with the verdict.
A missing or failed verdict-level reproduction is a `tool-failure`, so a reading-only concern from a reviewer with a dead command tool can never become a blocking code verdict.
The gate's re-execution is deliberately independent: it re-runs the helper itself in the review checkout with no network and none of the reviewer's provider credentials or account environment.
Reviewer helpers must therefore be self-contained and must not require reviewer-only variables to be set, even when a local receipt records `HOME` and the provider account selector.
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

The reviewer is a synchronous Codex or Pi agent invocation with a bounded timeout and a JSON output schema.
Normal runs take minutes and callers should budget them as remote agent work rather than a cheap local preflight.
PR claims are delimited as untrusted data, and the reviewer is directed to ignore embedded instructions and use focused evidence rather than duplicate no-mistakes' broad suite.
Later reviewers receive only a bounded projection of finding IDs, lifecycle state, severity, exact-head clearance, and proof digests.
Finding prose, reproduction output, test output, and lifecycle notes remain durable in the ledger but are never reinjected into a later reviewer prompt.
The Codex path pins `gpt-5.6-sol`, xhigh reasoning, noninteractive approval, an independent `CODEX_HOME`, the same account-bound `HOME`, and the exact review checkout.
The Pi path pins the roster model on its mapped provider (each registered cross-family model on its own slot, `gpt-5.6-sol` on `openai-codex`), xhigh reasoning, an independent `PI_CODING_AGENT_DIR`, a disposable private `HOME`, extension and context isolation, and JSON event output.
The globally installed Pi Fast Mode toggle is not used by this lane.
Crosscheck loads only its explicit verdict extension, and `pi-openai-fast-mode` targets OpenAI providers rather than the `fireworks-glm` custom provider.
New reviews deliberately use the regular GLM 5.2 selector rather than the historical Fast serving path.
An unavailable reviewer binary, sandbox, reviewer credential binding, verdict-level execution proof, or exact remote PR head records a `tool-failure` attempt when the live head is already known, and otherwise emits the same tool-failure class without fabricating a ledger run.
A ledger that cannot be read is the one stop that cannot record itself: appending a run to a file that failed to parse would risk destroying the durable findings it still holds, so the ledger is left exactly as it is and only the readable `crosscheck.md` report is rewritten, naming the parse failure so the cause is on disk rather than only in the exit status of a run nobody kept.
A reviewer that never reached its provider is also a `tool-failure` rather than an `unreviewed` attempt, and is the case that fails over.
The two are distinguished by evidence of model work: a Codex exit that wrote no result artifact or a Pi launch that never completed a turn means the account never spoke and the gate learned nothing about the code.
Recording that as `unreviewed` also manufactured a suspicion in the ledger, which reads like the reviewer raised a concern about the change when it had not started.
Failure banners quote what the reviewer actually reported rather than replacing it with a generic refusal.
A timeout, or a reviewer that reached the model and then produced a missing, empty, malformed, or wrong-head artifact, records an `unreviewed` attempt and exits nonzero.
A completed review whose changed implementation has no executable mutation-certification route records `cannot-certify`, names the exact missing route, and exits nonzero without fabricating either a code verdict or a pass.
An unresolved suspicion comes from a completed reviewer and records a `blocking` attempt instead of being conflated with an invalid review artifact.
This includes provider refusals that surface only as a stopped or silent agent.
`bin/fm-crosscheck.sh` refuses earlier than any of these when it cannot resolve a Python 3.11 or newer interpreter for `fm-crosscheck.py`: it prints a `CROSSCHECK UNREVIEWED` banner naming the requested and discovered versions, exits nonzero, and records no ledger run because nothing about the PR was examined.
That fail-closed banner keeps an interpreter defect from reading as a clear review; interpreter discovery order and the `FM_CROSSCHECK_PYTHON` override are owned by [configuration.md](configuration.md#toolchain).
Reviewer stdout plus stderr use a separate 16 MiB capture ceiling because a full agent transcript routinely exceeds the ordinary command budget.
`FM_CROSSCHECK_REVIEWER_MAX_CAPTURE_BYTES` can override that ceiling between 200,000 bytes and 64 MiB, and an invalid value fails closed before reviewer launch.
This remains a hard bound rather than truncation: Codex must still provide its separate authoritative result artifact, and Pi must complete its structured event stream.
Crossing the reviewer ceiling terminates the owned process tree and records a loud `unreviewed` attempt, and captured output alone never substitutes for a valid verdict.
Evidence and every other ordinary command retain the 200,000-byte aggregate stdout-plus-stderr ceiling, except the post-review checkout integrity inspection described above, which carries its own 4 MiB budget.
The final wait and process-pinned descendant cleanup remain inside the same absolute deadline.
Structured verdict artifacts are stable regular files bounded by the ordinary 200,000-byte ceiling before JSON decoding.
The durable ledger is bounded separately and fails closed when absent, symlinked, malformed, non-finite, or oversized.
The platform-specific containment limits and empirical mutation evidence are recorded in [crosscheck-bounded-io.md](crosscheck-bounded-io.md).
Reviewer result arrays are capped at 32 entries, at most 32 evidence executions are accepted, and all reproduction and mutation work shares a 900-second aggregate deadline by default.

## Installed external contracts

The external surface was observed on 2026-08-02 before implementation, rechecked on 2026-08-03 for nonempty TOON arrays, re-run against installed `gh-axi 0.1.25` on 2026-08-04, and extended with read-only merge-queue checks on 2026-08-08.
The 2026-08-04 recheck observed `gh-axi 0.1.25` and `codex-cli 0.146.0-alpha.9.2`.

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
The installed `/usr/bin/sandbox-exec` was also exercised with the generated profile: a write inside the allowed review directory succeeded, while sibling and `/private/tmp` writes failed with `Operation not permitted`.
On 2026-08-09 the Jest mutation route was exercised at relvino PR 1049 head `5649c234b0f258cde4d62870759e353fade5ff3d` in a fresh exact-head clone.
The gate selected Node 20.20.2 for the package's `20.x` declaration, used npm 10.8.2 and the tracked package lock to materialize Jest 29.7.0 offline with lifecycle scripts disabled, and ran the fixed `--runInBand --runTestsByPath --ci --no-cache --json` protocol under the no-network sandbox.
The tracked `V3PreviewPane.test.tsx` reported 33 executed and zero failed tests at baseline; replacing the session key with one shared key reported the same 33 executed tests with two failures, so the result demonstrated positive mutation detection rather than a runner-status inference.

## Validation evidence boundaries

`tests/fm-github-pr.test.sh` is hermetic coverage using checked-in TOON shapes.
The versioned fixtures it uses were observed from installed `gh-axi 0.1.25`.
Most of `tests/fm-crosscheck.test.sh` is hermetic coverage using observed-shape GitHub, Codex, Pi, and sandbox fakes.
Its `test_installed_sandbox_denies_shared_private_tmp` case is the exception: it invokes the real installed `/usr/bin/sandbox-exec` and verifies the generated proof profile denies shared host temporary state.
Its `test_pytest_runner_resolves_through_a_uv_aware_ladder` case is the named regression for runner-name resolution: it pins monorepo uv-project discovery, the skipped uv rung outside a project, the unchanged absent-runner refusal, and pytest's retained node-id support.
Its `test_missing_author_identity_reaches_normal_verdict` case is the named regression for a Pi lane without a captured account identity: the review reaches an ordinary clear verdict without an identity warning or downgrade.
Its `test_claude_reviewer_profile_is_retired` case proves the standing rule that Claude is not an accepted reviewer profile and never launches, and its `test_cross_family_reviewer_executes_bound_policy_profile`, `test_truncated_cross_family_verdict_is_never_a_verdict`, `test_cross_family_credential_binding_is_key_independent`, `test_cross_family_family_marker_is_bound_to_the_reviewer_model`, and `test_codex_fallback_family_is_loud_and_recorded` cases pin every registered lane's provider mapping, the refusal of a truncated verdict, key-independent endpoint binding, model-bound family provenance, and the loud durable fallback marker.
Its `test_same_model_relaxation_does_not_require_author_identity` case proves the explicit model-policy relaxation does not revive an author-account precondition.
`tests/fm-spawn-dispatch-profile.test.sh` separately proves a failed Pi identity capture remains nonfatal and the lane still launches.
Its `test_typescript_jest_mutation_proof_can_clear` and `test_inadequate_typescript_jest_coverage_stays_blocking` cases prove that package-governed Jest coverage can certify a TypeScript fix while a named Jest test that stays green under mutation keeps the finding blocking.
Its `test_preexisting_jest_runner_cannot_certify` case proves that a committed Jest-shaped output script is refused before package-manager materialization, and `test_local_fake_jest_package_cannot_certify` proves a lockfile-routed local fake package cannot substitute for official registry provenance.
Its `test_local_transitive_jest_package_cannot_certify` case keeps top-level Jest registry-authenticated while substituting a local `jest-cli`, and proves that every transitive runtime package must remain inside the authenticated closure.
Its `test_jest_runs_under_declared_node_major` case proves the selected Node path governs installation and both proof executions.
Its `test_typescript_without_usable_route_is_cannot_certify` case proves that an unsupported package-governed route writes and reports `CANNOT-CERTIFY` rather than silently clearing or manufacturing a code verdict.
Its `test_python_mutation_proof_is_byte_exact` case compares the complete normalized Python proof record to the pre-Jest shape so the new language route cannot drift existing pytest evidence.
Its `test_moved_default_branch_stays_reviewable` case is the named regression for base drift: it advances the fake default branch past the PR's branch point, then requires the run to review against the merge base, record it, and still verify.
Its `test_unavailable_reviewer_fails_over_to_the_next_account` case covers a failed Pi reviewer followed by a healthy Codex reviewer and asserts both attempts remain durable.
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
Codex uses its installed workspace-write sandbox, and Pi uses the explicit macOS profile described above.
Both permit test processes and provider network access, so this is containment for accidental or prompt-directed file mutation, not a guarantee that hostile repository code is safe to execute.
