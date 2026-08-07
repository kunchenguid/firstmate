# Upstream proposal: a supported credential seam for the GitHub PR step

This is a proposal for `kunchenguid/no-mistakes`, written to be turned into an upstream issue or pull request.
It is not a description of firstmate behavior; [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md) owns the local mitigation and the reason one was needed.

Evidence below was read from the upstream source at release 1.46.0, commit `20892e6`, and cross-checked against the installed binary at v1.41.2.

## Problem

The PR step cannot open a pull request when the daemon's environment carries a GitHub credential that is not authorized for pull-request creation, and there is no supported way to give that step a different credential.

GitHub forbids fine-grained personal access tokens from the GraphQL `createPullRequest` mutation.
A token of that class passes `gh auth status`, satisfies every REST call the earlier steps make, and then fails only at `gh pr create` with "Resource not accessible by personal access token".
Because `GITHUB_TOKEN` overrides `gh`'s own stored credential, any operator who exports one for unrelated tooling silently loses the PR step, and loses it at the end of a run that has already spent review, test, document, lint, and push.

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

## Proposal

Add a supported configuration knob that populates `StepContext.Env` for forge calls, so an operator can give the PR step a credential without changing the daemon's global environment.

Either of two shapes would resolve the problem; the first is smaller and matches the existing Bitbucket precedent.

### Option A: named environment variables for GitHub

Read a GitHub credential from named variables, exactly as Bitbucket already does:

- `NO_MISTAKES_GITHUB_TOKEN` - the token handed to `gh` for this repository's forge calls, exported into the step environment as `GH_TOKEN`.
- `NO_MISTAKES_GITHUB_HOST` - optional, for GitHub Enterprise Server.

This is a small change confined to host construction, it is symmetric with the Bitbucket provider, and it is discoverable in the existing environment reference.
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

- A repository whose daemon environment exports a `createPullRequest`-forbidden `GITHUB_TOKEN` completes the PR step when the new knob supplies an authorized credential.
- The configured credential is used for `pr create` and `pr edit`, and the resolution is visible in the step log without printing the credential.
- An absent knob preserves today's behavior exactly, including the existing skip conditions.
- A configured but unusable credential fails with a message naming the knob, rather than surfacing only `gh`'s own error text.

## Related improvement

Independently of the knob, the PR step's skip conditions could detect this class of failure earlier.
`gh auth status` proves authentication but not authorization for pull-request creation, so a run can pass every gate and fail on its last step.
Checking the credential's authorization for the mutation during the PR step's precondition phase would move the failure to where it can be acted on.
