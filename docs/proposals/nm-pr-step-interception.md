# Upstream proposal: supported GitHub credentials and CI verification

This is a proposal for `kunchenguid/no-mistakes`, written to be turned into an upstream issue or pull request.
It is not a description of firstmate behavior; [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md) owns the local mitigations and the reasons they were needed.

Evidence below was read from the upstream source at release 1.46.0, commit `20892e6`, and cross-checked against the installed binary at v1.41.2.

## PR credential problem

The PR step cannot open a pull request when the daemon's environment carries a GitHub credential that is not authorized for pull-request creation, and there is no supported way to give that step a different credential.

GitHub forbids fine-grained personal access tokens from the GraphQL `createPullRequest` mutation.
A token of that class passes `gh auth status`, satisfies every REST call the earlier steps make, and then fails only at `gh pr create` with "Resource not accessible by personal access token".
Because `GH_TOKEN` and `GITHUB_TOKEN` override `gh`'s own stored credential, with `GH_TOKEN` taking precedence between them, an operator who exports either for unrelated tooling can silently lose the PR step at the end of a run that has already spent review, test, document, lint, and push.

The failure is not detected by the PR step's skip conditions, which check that `gh` is installed and authenticated.
An authorized-for-everything-else token satisfies both.

## Why the current surface cannot express the fix

- `internal/scm/github` builds every forge call as an argument vector executed under the bare name `gh`, so the binary is resolved from the daemon's `PATH`.
- The GitHub host is constructed in `internal/pipeline/steps/host.go` from a `CmdFactory` that closes over `stepCmd`, with no path or credential parameter.
- Neither `~/.no-mistakes/config.yaml` nor `.no-mistakes.yaml` carries a GitHub credential, a `gh` path, or a PR-step command override.
  `agent_path_override` is scoped to agent binaries; `commands.*` is scoped to lint, test, and format.
- The daemon resolves its environment once from the login shell at startup and caches it, so the only lever an operator has is what that login shell exported at that moment, applied uniformly to every repository.

There is a clear asymmetry between providers.
Bitbucket Cloud credentials are read from named environment variables through `bitbucket.NewClientFromEnv(sctx.Env)`, using `NO_MISTAKES_BITBUCKET_EMAIL`, `NO_MISTAKES_BITBUCKET_API_TOKEN`, and `NO_MISTAKES_BITBUCKET_API_BASE_URL`.
GitHub has no comparable knob, so the provider with the most users is the one an operator cannot configure.

## The mechanism already exists

No new execution machinery is required.
`stepCmd` in `internal/pipeline/steps/common_exec.go` already honors a step-scoped environment:

- when `StepContext.Env` is non-empty it resolves the command through `findInCustomPath`, using the `PATH` carried in that environment rather than the daemon's;
- it sets `cmd.Env` from `mergeEnv(sctx.Env)`, so a step-scoped credential reaches the subprocess;
- when the custom `PATH` exists but does not contain the command, it fails closed with `exec.ErrNotFound` rather than silently falling back to the daemon's `PATH`.

`stepGitRun` documents the intent directly: it respects `sctx.Env` "so step-scoped PATH and credential environment stay in effect".

The gap is only that nothing populates the field outside tests.
`internal/pipeline/pipeline.go` declares it as `Env []string // extra environment variables for subprocesses (used in tests)`, and the executor's `StepContext` literal never sets it.

## Credential proposal

Add a supported credential input that populates `StepContext.Env` for forge calls, so an operator can give GitHub subprocesses a credential without exposing it through ambient `GH_TOKEN` or `GITHUB_TOKEN` to every daemon subprocess.

Either of two shapes would resolve the problem; the first is smaller and matches the existing Bitbucket precedent.

### Option A: named environment variables for GitHub

Read a GitHub credential from named variables, exactly as Bitbucket already does:

- `NO_MISTAKES_GITHUB_TOKEN` - the token handed to `gh` for GitHub forge calls handled by this daemon.
  Before launching `gh`, remove inherited `GH_TOKEN` and `GITHUB_TOKEN` from the child environment and export this value as `GH_TOKEN`, so neither ambient variable can override the configured credential.
- `NO_MISTAKES_GITHUB_HOST` - optional, for GitHub Enterprise Server.

This is a small change confined to host construction, it is symmetric with the Bitbucket provider, and it is discoverable in the existing environment reference.
Like the Bitbucket variables, this option is daemon-global rather than per-repository.
It does not, on its own, let an operator route a call through a credential helper that never materializes a token in a config file or an environment the daemon can be inspected for.

### Option B: a configured command prefix for forge calls

Allow the repository config to declare a prefix that forge commands are executed through:

```yaml
# .no-mistakes.yaml
scm:
  github:
    command_prefix: ["my-credential-helper", "run", "--"]
```

`stepCmd` would prepend the prefix to the `gh` vector for that provider.
This covers the credential-helper case, where the token is injected by a vault at call time and never written to disk.
It is strictly more expressive than Option A and correspondingly more sensitive, so it belongs behind the same trust boundary as `commands.*`, which already executes arbitrary shell from a trusted default-branch config and is governed by `allow_repo_commands` and `disable_project_settings`.

Option A alone would resolve the reported failure.
Option B additionally removes the need for any out-of-band `PATH` interception.

## Acceptance criteria for the upstream change

- A repository whose daemon environment exports a `createPullRequest`-forbidden `GH_TOKEN`, `GITHUB_TOKEN`, or both completes the PR step when the new credential input supplies an authorized credential.
- The configured credential is used for `pr create` and `pr edit`, and the resolution is visible in the step log without printing the credential.
- An absent credential input preserves today's behavior exactly, including the existing skip conditions.
- A configured but unusable credential fails with a message naming the knob, rather than surfacing only `gh`'s own error text.

## Related improvement

Independently of the knob, the PR step's skip conditions could detect this class of failure earlier.
`gh auth status` proves authentication but not authorization for pull-request creation, so a run can pass every gate and fail on its last step.
Checking the credential's authorization for the mutation during the PR step's precondition phase would move the failure to where it can be acted on.

## CI verification problem

The same fine-grained personal access token can read pull requests and GitHub Actions workflow runs while GitHub denies the `statusCheckRollup` selection behind `gh pr checks`.
The verified response is a GraphQL 403 whose error path contains a whole `statusCheckRollup` component, including the currently observed deeper path `repository.pullRequest.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0`.
No-mistakes currently treats that command failure as unreadable CI state and polls again, even when Actions already has terminal evidence for the exact pull-request head.
The existing `statusCheckRollup` path is more complete because it can include third-party check providers and remains the required primary path.
The Actions workflow-runs API is a proven least-privilege fallback for repositories whose relevant required evidence is entirely in GitHub Actions.

The observed 3.3-hour cost of this gap came from diagnosing the authorization boundary and implementing and verifying a local fail-closed workaround.

## CI verification proposal

Keep the current `statusCheckRollup` read unchanged as the primary CI source.
Enter the Actions fallback only when that read fails with GitHub's exact personal-token authorization sentence and its GraphQL error path contains a whole `statusCheckRollup` component.
Replay every other error unchanged, including unrelated 403 responses, similar component names, and non-authorization failures.

The fallback must derive its evidence from the repository and pull-request number already owned by the CI step, then apply all of these bindings before it may report green:

- Read the current pull-request head SHA from the exact repository and pull-request number.
- Paginate the active Actions workflow inventory and the workflow-runs endpoint filtered by that exact head SHA.
- Accept only `pull_request` or `pull_request_target` runs whose repository full name, pull-request association number, association head SHA, and run head SHA all match the requested repository, pull request, and current head.
- Require one relevant run for every active workflow because this credential cannot read branch-protection required checks or repository rulesets; an upstream implementation may narrow that conservative set only when it has an exact readable required-workflow authority.
- Collapse reruns by run identity, retain only the highest published `run_attempt`, and reject conflicting records for that latest attempt or multiple equally current runs as ambiguous.
- Paginate each selected run's jobs with `filter=all`, retain only jobs for the selected latest attempt and exact head SHA, and require a non-empty unambiguous job set.
- Re-read the pull-request head after all pages are collected and discard the result if it changed.

A workflow is green only when its selected run is completed with conclusion `success` and every retained exact-attempt job is completed with conclusion `success`.
A queued or in-progress run or job is pending.
A failed, timed-out, action-required, startup-failed, cancelled, unexpectedly skipped, neutral, or stale run or job is terminal and not green.
An absent workflow, absent job set, unrelated run, stale or wrong-head run, malformed record, duplicate conflict, or selection tie is missing or ambiguous evidence and not green.
Any unreadable head, workflow, run, jobs, or head-recheck API response is a typed terminal API failure that preserves the underlying GitHub diagnostic.

Pending, missing, and ambiguous evidence must have a persisted deadline keyed by repository, pull-request number, and head SHA.
Before the deadline the CI step may continue polling with a typed actionable reason.
At the deadline it must return a typed failed check, reset the deadline when the head changes or evidence becomes terminal, and never warn indefinitely.
The returned checks must preserve the public JSON fields no-mistakes already consumes so the monitor can distinguish pass, pending, failure, cancellation, skipping, API failure, head drift, and evidence timeout without parsing prose.

This fallback cannot recover third-party provider checks hidden behind the forbidden Checks API.
If a repository requires such a provider and no exact required-check authority is readable, the monitor must fail closed rather than treating Actions-only evidence as complete.

## CI verification acceptance matrix

Exercise the behavior through the public CI-step command boundary, not only through internal helpers:

- Primary success returns the existing `statusCheckRollup` result and never calls the Actions fallback.
- Exact-repository, exact-PR, exact-head Actions success returns green after the primary read receives the verified denial.
- Queued and in-progress runs or jobs return pending, while concrete failed, cancelled, skipped, neutral, stale, timed-out, action-required, and startup-failed states never return green.
- Missing active-workflow runs, missing jobs, malformed evidence, conflicting latest attempts, and equally current runs remain non-green and become typed failures at the deadline.
- Unrelated, wrong-repository, wrong-PR, wrong-head, stale, and non-PR-triggered runs cannot certify the pull request.
- Multi-page workflow, run, and job responses are complete; a later-page failure is decisive.
- A later successful rerun supersedes its older failed attempt, while jobs from older attempts cannot affect or certify the selected attempt.
- A pull-request head change during collection produces typed head drift rather than a stale verdict.
- Every API failure produces a typed failed check, preserves the underlying error, and cannot become another indefinitely repeated unreadable poll.
- Repositories with required third-party checks remain closed unless an exact required-check authority proves the Actions evidence complete.
