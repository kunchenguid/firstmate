# Pull-request credential routing verification

Repeatable evidence for the `gh` shim that routes pull-request mutations through `bin/fm-gh.sh`.
Current behavior and rationale are owned by [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md), the configuration schema by [`../configuration.md`](../configuration.md) ("Pull-request credential"), and the upstream ask by [`../proposals/nm-pr-step-interception.md`](../proposals/nm-pr-step-interception.md); this page records evidence only.

Date: 2026-08-06.
Comparison base: `main` at `fb368dc`.
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

## Interception cannot be scoped to a task worktree

The `pr` step runs in the no-mistakes daemon process, which resolves its environment once from the login shell at startup and caches it.
Nothing placed inside a task worktree is on the `PATH` that resolves `gh` for that step, so a shim must be installed on the daemon's own `PATH` and is `PATH`-wide by construction.

## Routing behavior

`tests/fm-gh-shim.test.sh` (8 assertions) drives the shim and wrapper with a fake `gh` that records its argv and the credential it received, plus a fake credential runner, touching no network and no real `gh`.
It covers the exact argument vector the no-mistakes PR step builds (`pr create --head <ref> --base <base> --repo <slug> --title <title> --body-file -`) reaching the real `gh` unmodified with the configured credential injected; `pr list`, `pr view`, and `api` passing through without spending that credential; an unconfigured home execing commands unchanged; the first non-comment, whitespace-trimmed prefix line winning; a credential that re-resolves `gh` from `PATH` routing at most once rather than recursing; and the installer creating, verifying precedence for, refusing to overwrite a foreign `gh`, and removing only a link it owns.

One assertion is a legacy-shell regression and self-skips where no bash 3.2 exists.
Under `set -u`, bash 3.2 rejects an empty array's `"${arr[@]}"` expansion as an unbound variable, which broke the unconfigured pass-through path that every home without `config/gh-credential` takes; the observed failure was `bin/fm-gh.sh: line 81: PREFIX[@]: unbound variable` on GNU bash 3.2.57, the system bash macOS 26.5 ships. The wrapper now expands the prefix as `${PREFIX[@]+"${PREFIX[@]}"}`, and all three scripts were exercised under that shell.

```console
$ bash tests/fm-gh-shim.test.sh
ok - gh pr create routes through fm-gh.sh and reaches the real gh with the configured credential
ok - pr list, pr view, and api pass through the shim without the privileged credential
ok - fm-gh.sh with no config/gh-credential execs the command unchanged
ok - fm-gh.sh reads only the first non-empty, non-comment, trimmed prefix line
ok - the shim routes at most once even when the credential re-resolves gh from PATH
ok - fm-gh.sh runs both the unconfigured and configured paths under bash 3.2
ok - the installer creates, verifies, reports precedence for, and removes the shim
ok - the installer refuses to overwrite or remove a gh it does not own
```
