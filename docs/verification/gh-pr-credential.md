# GitHub shim routing verification

Repeatable evidence for the `gh` shim that routes pull-request mutations through `bin/fm-gh.sh` and recovers exact-head workflow verdicts through `bin/fm-gh-ci-fallback.sh`.
Current behavior and rationale are owned by [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md), the configuration schema by [`../configuration.md`](../configuration.md) ("Pull-request credential"), and the upstream ask by [`../proposals/nm-pr-step-interception.md`](../proposals/nm-pr-step-interception.md); this page records evidence only.

Date: 2026-08-09.
Comparison base: `fork/main` at `1c9ebcb6`.
Shell: GNU bash 5.3.9 (macOS 26.5).
`gh` 2.92.0.
no-mistakes v1.41.2 installed; upstream source read at release 1.46.0, commit `20892e6`.

## The failure this addresses is real and is an authorization difference, not an identity difference

Both credentials on this machine resolve to the same GitHub login, so identity alone does not distinguish them.
The difference is token class, and it appears only at the `createPullRequest` mutation.
The probe below targets a repository the credential cannot write to, with a head ref that does not exist, so GitHub rejects it either way and nothing is created.

```console
$ Q='mutation { createPullRequest(input: {repositoryId: "MDEwOlJlcG9zaXRvcnkx", baseRefName: "main", headRefName: "fm-probe-does-not-exist", title: "probe"}) { pullRequest { number } } }'

$ gh api graphql -f query="$Q"      # ambient fine-grained token
type: FORBIDDEN | msg: Resource not accessible by personal access token

$ bin/fm-gh.sh gh api graphql -f query="$Q"      # via config/gh-credential
type: UNPROCESSABLE | msg: Head sha can't be blank, Base sha can't be blank, No commits between main and fm-probe-doe
```

`FORBIDDEN` is GitHub refusing the token class before evaluating the request.
`UNPROCESSABLE` is the request passing authorization and failing only on ref resolution, which is the decisive evidence that the wrapped credential is authorized for the mutation.

The wrapper reports its configured state and resolved identity without printing the credential:

```console
$ bin/fm-gh.sh --check
credential prefix: configured (<home>/config/gh-credential)
identity: quinnbot-ai
```

## No supported configuration seam exists in no-mistakes

Read from the upstream source at release 1.46.0 and cross-checked against the installed v1.41.2 binary.

- `internal/scm/github/github.go` executes every forge call by the bare name `gh`, including `CreatePR` (`gh pr create`), `UpdatePR` (`gh pr edit`), and `FindPR` (`gh pr list`).
- `internal/pipeline/steps/host.go` builds the GitHub host from a `CmdFactory` closing over `stepCmd`, with no binary-path or credential parameter.
- `internal/pipeline/steps/common_exec.go`'s `stepCmd` honors a step-scoped `PATH` and credential environment whenever `StepContext.Env` is non-empty, and fails closed with `exec.ErrNotFound` when a custom `PATH` lacks the command.
- `internal/pipeline/pipeline.go` declares that field as `Env []string // extra environment variables for subprocesses (used in tests)`, and the executor's `StepContext` literal never sets it, so the seam is unreachable from configuration.
- Bitbucket Cloud reads credentials from `NO_MISTAKES_BITBUCKET_EMAIL`, `NO_MISTAKES_BITBUCKET_API_TOKEN`, and `NO_MISTAKES_BITBUCKET_API_BASE_URL` via `bitbucket.NewClientFromEnv(sctx.Env)`; GitHub has no equivalent.

The pipeline's nine steps, read from the daemon's own `step_results` records, are `intent`, `rebase`, `review`, `test`, `document`, `lint`, `push`, `pr`, `ci`.

The installed v1.41.2 CI implementation calls `gh pr checks <selector> --repo <owner/repo> --json name,state,bucket,completedAt`.
Current upstream adds `link` to that exact JSON field set.
Both implementations treat a nonzero check-runs read as unavailable CI state, so a persistent 403 cannot become a terminal verdict without a fallback.

## The narrow credential exposes Actions evidence but not required-check policy

The current public executable path reproduces the `statusCheckRollup` denial against pull request 14 while read-only REST calls with the same ambient credential resolve its exact head and workflow runs.

```console
$ npx -y gh-axi pr checks 14 --repo=quinnbot-ai/ff-manager
error: "GraphQL: Resource not accessible by personal access token (repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)"
code: UNKNOWN

$ npx -y gh-axi api repos/quinnbot-ai/ff-manager/pulls/14 --jq '{number: .number, head_sha: .head.sha, base: .base.ref, state: .state}'
base: main
head_sha: 7d05c902006bfbc3bca9f750f823a3a86c7a6a03
number: 14
state: open

$ npx -y gh-axi api 'repos/quinnbot-ai/ff-manager/actions/runs?branch=feat%2Fdaily-browser-research&event=pull_request&per_page=5' --jq '{total_count: .total_count, runs: [.workflow_runs[] | {id, workflow_id, run_attempt, head_sha, status, conclusion, event, pull_requests: [.pull_requests[].number]}]}'
runs[4]:
  - conclusion: success
    event: pull_request
    head_sha: 7d05c902006bfbc3bca9f750f823a3a86c7a6a03
    id: 31352872155
    pull_requests[1]: 14
    run_attempt: 1
    status: completed
    workflow_id: 314271020
total_count: 4

$ npx -y gh-axi api 'repos/quinnbot-ai/ff-manager/actions/runs/31352872155/jobs?filter=all&per_page=100' --jq '{total_count: .total_count, jobs: [.jobs[] | {id, run_id, run_attempt, name, head_sha, status, conclusion}]}'
jobs[1]{conclusion,head_sha,id,name,run_attempt,run_id,status}:
  success,7d05c902006bfbc3bca9f750f823a3a86c7a6a03,93346815543,offline-quality,1,31352872155,completed
total_count: 1
```

The workflow inventory is readable and identifies one active workflow named `CI` at `.github/workflows/ci.yml`.
Both the branch-protection required-status-check endpoint and the repository-rulesets endpoint return `FORBIDDEN: Insufficient permissions for this action` with the same credential.
That boundary is why the local fallback conservatively requires every active Actions workflow, while the upstream proposal asks no-mistakes to obtain an exact required-check set before certifying green.

## Divergent gate repository diagnosis

The trigger was a credential-routed `gh pr create` or `gh pr edit` invocation without an explicit `--repo` or `-R`.
The masking condition was a no-mistakes gate checkout whose `origin` named the upstream parent while the repository registration's canonical push target named a fork.
The visible symptom was an explicit upstream target inserted by the shim, which caused the `fm-gh-ci-fallback-signature` delivery to open `kunchenguid/firstmate` PR 2038 instead of `quinnbot-ai/firstmate` PR 106.
A second delivery, `fm-gh-ci-fallback-slurp`, reproduced the same misrouting by opening upstream PR 2040 before fork redelivery.
Both upstream pull requests were closed, establishing recurrence rather than a one-off run failure.

The 2026-08-09 incident leaves all three layers visible on disk.
`$HOME/.no-mistakes/state.sqlite` registers the Firstmate repository with `upstream_url=https://github.com/kunchenguid/firstmate.git` and `fork_url=https://github.com/quinnbot-ai/firstmate.git`.
The corresponding `$HOME/.no-mistakes/repos/<repo-id>.git` gate has `origin=https://github.com/kunchenguid/firstmate.git`.
The run's `push.log` says `pushing to fork https://github.com/quinnbot-ai/firstmate.git`, while its `pr.log` records `https://github.com/kunchenguid/firstmate/pull/2038`.
That separates the proven fork-aware delivery path from the failing gate-origin PR path without relying on account identity or remote naming conventions.

Commit `96f668c` introduced origin pinning to prevent `gh` from inferring a fork's parent when an implicit PR target was used.
That change correctly failed closed when `origin` was absent and preserved explicit repository selection, but it assumed that the gate repository's `origin` was also the delivery target.
No-mistakes' repository model disproves that assumption: `Repo.PushURL()` chooses a configured `fork_url` before `upstream_url`, and the push step uses that result while the gate's `origin` can remain upstream.
The canonical owner is therefore the no-mistakes repository registration, with the registered checkout and its `no-mistakes` remote used to corroborate gate identity.

The behavioral counterfactual creates a registered checkout with `origin=kunchenguid/firstmate`, `fork=quinnbot-ai/firstmate`, and a gate checkout with `origin=kunchenguid/firstmate`.
Before the fix, the fixture selected `kunchenguid/firstmate` and failed the expected fork-target assertion.
After the fix, both `gh pr create` and `gh pr edit` name `quinnbot-ai/firstmate`, and the recorded argument stream contains no `kunchenguid/firstmate` target.
Disconfirming cases prove the resolver does not merely prefer a remote named `fork`: an ordinary registration with only a canonical `origin` still succeeds, explicit `--repo` and `-R` remain byte-for-byte unchanged, and missing, contradictory, malformed, or non-GitHub registration evidence stops before the real `gh` runs.

## Cross-home merge recursion diagnosis

The merge incident had a distinct trigger, masking condition, and symptom from the pull-request target defect.
The trigger was `fm-merge-execute.sh` running from one Firstmate home while the first `gh` on `PATH` resolved to another home's installed shim, or while that installed target changed between selection and execution during a home update.
The masking condition was path identity: commit `6cbc520a` taught the GraphQL capture to skip only the shim file beside the running merge script, and its regression fixture symlinked `gh` back to that exact file.
The symptom was the generated capture wrapper executing the foreign shim, followed by the foreign shim selecting the generated wrapper as its real `gh`, producing the exact recursive edge `capture wrapper -> foreign fm-gh-shim -> capture wrapper`.
Each wrapper entry also created a `tee` process, so the tree rooted at the guarded merge grew until the host exceeded 4,000 processes and the affected merge machinery was killed.

The repository-lock path deliberately starts `fm-merge-execute.sh` once more with an inherited locked descriptor.
Inspection of the current scripts found no edge from the GitHub shim or capture wrapper back to `fm-merge-execute.sh`, so the unbounded edge was below that one intended re-entry rather than repeated merge-operator launches.
The new merge depth marker nevertheless proves that the lock handoff occurs exactly once and fails with exit 70 if a mid-flight script update loses or contradicts the inherited lock state.

The affected fork-manager pull request used an aligned project gate, while the stale upstream Firstmate gate remained elsewhere in the same machine-wide shim environment.
That is disconfirming evidence against gate `origin` divergence as the direct recursion cause: origin divergence causes PR target misrouting, while cross-home executable identity and mid-flight replacement cause capture recursion.
An older open prospecting pull request was also inspected, but its durable record attributes the open state to an explicit merge-authority hold and later branch-custody divergence, not to the recursion path.

The bounded pre-fix reproduction placed a re-resolving `gh` ahead of the fake genuine binary and capped it after four invocations.
The same-home shim case passed, while the adversarial case reached all four entries and returned only a flattened exit 1.
After the fix, a current foreign-home shim is recognized by a side-effect-free probe and skipped, preserving one GraphQL request and one exact SHA-conditioned mutation.
An unrecognized stale or replaced executable that re-enters `PATH` reaches the selected executable exactly once, reaches the GraphQL command exactly once, and stops at the second capture-wrapper entry with the typed exit 70 diagnostic.
Separate fixtures prove the shim permits the existing one-time credential re-resolution but stops a third shim entry, the credential wrapper stops its first recursive prefix entry, and the merge operator stops an unlocked re-entry before mutation.

## Interception cannot be scoped to a task worktree

The `pr` step runs in the no-mistakes daemon process, which resolves its environment once from the login shell at startup and caches it.
Nothing placed inside a task worktree is on the `PATH` that resolves `gh` for that step, so a shim must be installed on the daemon's own `PATH` and is `PATH`-wide by construction.

## Routing behavior

The routing mechanism is owned only by [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md); this section records its empirical verification.

`tests/fm-gh-shim.test.sh` drives the public shim and wrapper interfaces with local fakes and disposable Git repositories, touching no network and no real `gh`.
The fork-target fixture creates a complete no-mistakes repository registration, bare gate, and linked worktree, so the implicit target is exercised from the same divergent topology as the incident.
Additional adversarial cases cover a normal canonical origin, exact explicit repository preservation, an unregistered checkout, a missing database record, a registered target contradicted by the source checkout's remotes, a malformed target, and a non-GitHub target.
`tests/fm-pr-merge.test.sh` drives protected GitHub merge capture through the public merge interface without a shim, through a same-home shim, and through a current shim copied into a distinct Firstmate-home path.
Those valid paths preserve the single GraphQL request and exact SHA-conditioned merge mutation.
Its reentrant executable fixture would reproduce the stale or mid-update loop but carries its own four-entry safety cap; the product guard now stops it at one selected-executable invocation with exit 70 before the cap can fire.
The same suite proves the merge operator's inherited-lock handoff is the only accepted self-entry.

The CI cases reproduce the check-runs authorization boundary and exercise the fallback through the shim's public `gh` interface.
The fake applies the helper's real jq expressions to each raw workflow, run, and job page in turn and sorts result keys, so the assertions cover the same transformation `gh api --paginate --jq` performs, and it refuses `--slurp` alongside `--jq` exactly as GitHub CLI 2.92.0 does.
The primary-path case proves a readable `gh pr checks` result bypasses every Actions API.
The green fallback case provides a failed workflow under a stale SHA, a successful workflow associated with the current PR head, and explicit Actions-only authority for the exact repository, then asserts that the Actions endpoint contains `head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` and that the result is `bucket: pass`.
It also configures a distinct PR-capable token and proves that every CI call retains only the ambient narrow token.
The red cases map every terminal non-success Actions conclusion to `bucket: fail`, preserve each provider conclusion in `state`, and apply the no-mistakes consumer's public bucket interpretation to prove none can certify green.
The zero-run case emits a pending placeholder, and separate cases prove an unrelated run, a wrong-head run, and one successful run beside a missing active workflow cannot certify green.
The rerun case keeps only the latest attempt, while conflicting latest-attempt records remain explicit ambiguous evidence.
A paginated-jobs case puts a skipped job on the second page and proves workflow-level success cannot certify green over it.
A two-poll deadline case proves pending or missing evidence becomes a typed terminal failure at the configured bound.
A multi-page case maps cancelled and skipped workflows to failure while retaining their provider states, and keeps a queued workflow pending.
The flag-compatibility case first proves the fake rejects `--paginate --slurp --jq` before asserting that the fallback reaches a verdict against it, keeps runs from every page, and never sends `--slurp`, so the case cannot pass vacuously.
The dependency case proves an unavailable Python runtime emits typed terminal JSON instead of becoming an unreadable poll result.
The API-failure cases prove the underlying `gh` diagnostics for workflow-runs and both PR-head reads reach stderr beside typed synthetic failed checks.
Those terminal failures and the moving-head case all clear the repository-and-PR-keyed pending deadline before returning.
The deeper-denial-path case drives `(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)`, the denial GitHub returns today, and reaches the same exact-head green verdict the shorter historical path reaches.
The unrelated-failure case proves generic HTTP 403 responses, denials for other APIs, a denial whose path only begins with those characters (`node.statusCheckRollupSummary.nodes.0`), and non-403 failures never reach the fallback API, while the unsupported-shape case proves only the two literal no-mistakes argument vectors enter the capturing helper.
The completeness case proves green Actions evidence fails closed without exact repository-level Actions-only authority, because the workflow-runs API cannot reproduce third-party check-provider evidence hidden behind check-runs.

## GitHub CLI 2.92.0 rejects `--slurp` whenever `--jq` is present

This is why the exact-head read paginates without `--slurp` and aggregates the per-page results itself.

```console
$ E="repos/quinnbot-ai/ff-manager/actions/runs?head_sha=083549b141e8edb460d6e46be222b52f1cd054a5&per_page=100"

$ gh api -X GET "$E" --paginate --slurp --jq '.[]'
the `--slurp` option is not supported with `--jq` or `--template`

$ gh api -X GET "$E" --paginate --jq '.workflow_runs[] | {name: .name, status: .status}'
{"name":"CI","status":"completed"}
```

The second form shows the two properties the aggregation relies on: `gh` applies the expression to each page separately, and prints one compact JSON value per line with its object keys sorted.
Forcing a page break with `per_page=1` against a head carrying two runs shows every page still reaching the output:

```console
$ gh api -X GET "repos/quinnbot-ai/ff-manager/actions/runs?head_sha=0a451abe383794e563b60e6b2f8d64fdb2e58f91&per_page=1" --paginate --jq '.workflow_runs[] | {name: .name, id: .id}'
{"id":31343233713,"name":"CI"}
{"id":31343206757,"name":"CI"}
```

The same `gh` and the same ambient credential reach a terminal green verdict through the helper's supported invocation:

```console
$ bin/fm-gh-ci-fallback.sh "$(command -v gh)" pr checks 14 --repo quinnbot-ai/ff-manager --json name,state,bucket,completedAt,link
[{"bucket":"pass","completedAt":"2026-08-09T23:13:37Z","link":"https://github.com/quinnbot-ai/ff-manager/actions/runs/31341360264","name":"CI","state":"success"}]
```

One case is a legacy-shell regression and self-skips where no bash 3.2 exists.
Under `set -u`, bash 3.2 rejects an empty array's `"${arr[@]}"` expansion as an unbound variable, which broke the unconfigured pass-through path that every home without `config/gh-credential` takes; the observed failure was `bin/fm-gh.sh: line 81: PREFIX[@]: unbound variable` on GNU bash 3.2.57, the system bash macOS 26.5 ships.
The wrapper now expands the prefix as `${PREFIX[@]+"${PREFIX[@]}"}`, and both wrapper paths were exercised under that shell.

```console
$ bash tests/fm-gh-shim.test.sh
ok - gh pr create without --repo uses the registered canonical fork target
ok - a normal canonical origin routes safely despite repository-like option values
ok - caller-supplied --repo and -R are preserved exactly
ok - credential-routed pr edit refuses without a canonical registration
ok - missing canonical target evidence fails closed
ok - contradictory canonical target evidence fails closed
ok - malformed and non-GitHub canonical targets fail closed
ok - a readable primary status-check rollup bypasses the Actions fallback
ok - a check-runs 403 reaches a green exact-head workflow verdict without the privileged token
ok - a denial naming statusCheckRollup deeper in its path still reaches the exact-head verdict
ok - a check-runs 403 reaches a red exact-head workflow verdict
ok - zero exact-head workflow runs remain explicitly pending
ok - an unrelated exact-head workflow cannot certify the PR green
ok - the latest rerun attempt supersedes an older failed attempt
ok - a skipped job on a later page prevents workflow-level success
ok - one successful workflow cannot hide a missing active workflow
ok - conflicting latest-attempt evidence fails closed as ambiguous
ok - a stale workflow run cannot certify the current PR head
ok - missing or pending fallback evidence stops at a hard deadline
ok - paginated exact-head runs map cancellation, skipping, and pending buckets
ok - exact-head pagination reaches a verdict on a gh that rejects --slurp with --jq
ok - a failed workflow-runs read becomes a typed failure and keeps the real errors visible
ok - a moving PR head cannot emit a stale workflow verdict
ok - unrelated check failures are preserved without an API fallback
ok - unsupported gh pr checks shapes exec the real gh directly
ok - pr list, pr view, and api pass through the shim without the privileged credential
ok - fm-gh.sh with no config/gh-credential execs the command unchanged
ok - configured fm-gh.sh exposes only the prefix-injected GitHub token
ok - fm-gh.sh reads only the first non-empty, non-comment, trimmed prefix line
ok - fm-gh.sh ignores credential comments after trimming whitespace
ok - the shim routes at most once even when the credential re-resolves gh from PATH
ok - the gh shim bounds repeated PATH resolution to two real-gh invocations
ok - the credential wrapper bounds a recursive configured prefix to one invocation
ok - fm-gh.sh runs both the unconfigured and configured paths under bash 3.2
ok - the installer creates, verifies, reports precedence for, and removes the shim
ok - the installer refuses to overwrite or remove a gh it does not own
ok - the installer refuses a foreign gh symlink and leaves it intact
```
