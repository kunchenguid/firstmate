# GitHub shim routing verification

Repeatable evidence for the `gh` shim that routes pull-request mutations through `bin/fm-gh.sh` and recovers exact-head workflow verdicts through `bin/fm-gh-ci-fallback.sh`.
Current behavior and rationale are owned by [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md), the configuration schema by [`../configuration.md`](../configuration.md) ("Pull-request credential"), and the upstream ask by [`../proposals/nm-pr-step-interception.md`](../proposals/nm-pr-step-interception.md); this page records evidence only.

Date: 2026-08-09.
Comparison base: `fork/main` at `ae95570`.
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

## Interception cannot be scoped to a task worktree

The `pr` step runs in the no-mistakes daemon process, which resolves its environment once from the login shell at startup and caches it.
Nothing placed inside a task worktree is on the `PATH` that resolves `gh` for that step, so a shim must be installed on the daemon's own `PATH` and is `PATH`-wide by construction.

## Routing behavior

The routing mechanism is owned only by [`../no-mistakes-pr-credential.md`](../no-mistakes-pr-credential.md); this section records its empirical verification.

`tests/fm-gh-shim.test.sh` drives the public shim and wrapper interfaces with local fakes, touching no network and no real `gh`.
`tests/fm-pr-merge.test.sh` drives protected GitHub merge capture through the public merge interface both without the shim and with a symlink to this repository's shim prefixed on `PATH`, and proves both paths preserve the single GraphQL request and exact SHA-conditioned merge mutation.

Eight CI cases reproduce the check-runs authorization boundary and exercise the fallback through the shim's public `gh` interface.
The fake applies the helper's real jq expression to paginated raw workflow-run fixtures, so the assertions cover the same transformation `gh api --paginate --slurp --jq` performs.
The green case provides a failed workflow under a stale SHA and a successful workflow under the PR head, then asserts that the only Actions endpoint called contains `head_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa` and that the result is `bucket: pass`.
It also configures a distinct PR-capable token and proves that every CI call retains only the ambient narrow token.
The red case maps an exact-head workflow failure to `bucket: fail` and preserves its Actions link.
The zero-run case emits a pending placeholder, and a multi-page case maps cancelled, skipped, and queued workflows to the cancellation, skipping, and pending buckets.
The moving-head case refuses a verdict when the PR advances during pagination.
The deeper-denial-path case drives `(node.statusCheckRollup.nodes.0.commit.statusCheckRollup.contexts.nodes.0)`, the denial GitHub returns today, and reaches the same exact-head green verdict the shorter historical path reaches.
The unrelated-failure case proves generic HTTP 403 responses, denials for other APIs, a denial whose path only begins with those characters (`node.statusCheckRollupSummary.nodes.0`), and non-403 failures never reach the fallback API, while the unsupported-shape case proves only the two literal no-mistakes argument vectors enter the capturing helper.
These fixtures establish GitHub Actions behavior only; the workflow-runs API cannot reproduce third-party check-provider evidence hidden behind check-runs.

One case is a legacy-shell regression and self-skips where no bash 3.2 exists.
Under `set -u`, bash 3.2 rejects an empty array's `"${arr[@]}"` expansion as an unbound variable, which broke the unconfigured pass-through path that every home without `config/gh-credential` takes; the observed failure was `bin/fm-gh.sh: line 81: PREFIX[@]: unbound variable` on GNU bash 3.2.57, the system bash macOS 26.5 ships.
The wrapper now expands the prefix as `${PREFIX[@]+"${PREFIX[@]}"}`, and both wrapper paths were exercised under that shell.

```console
$ bash tests/fm-gh-shim.test.sh
ok - gh pr create without --repo injects its checkout origin into the credential route
ok - repository-like option values cannot suppress origin targeting
ok - caller-supplied --repo and -R always win over the checkout origin
ok - credential-routed pr edit without --repo refuses when origin is unavailable
ok - a check-runs 403 reaches a green exact-head workflow verdict without the privileged token
ok - a denial naming statusCheckRollup deeper in its path still reaches the exact-head verdict
ok - a check-runs 403 reaches a red exact-head workflow verdict
ok - zero exact-head workflow runs remain explicitly pending
ok - paginated exact-head runs map cancellation, skipping, and pending buckets
ok - a moving PR head cannot emit a stale workflow verdict
ok - unrelated check failures are preserved without an API fallback
ok - unsupported gh pr checks shapes exec the real gh directly
ok - pr list, pr view, and api pass through the shim without the privileged credential
ok - fm-gh.sh with no config/gh-credential execs the command unchanged
ok - configured fm-gh.sh exposes only the prefix-injected GitHub token
ok - fm-gh.sh reads only the first non-empty, non-comment, trimmed prefix line
ok - fm-gh.sh ignores credential comments after trimming whitespace
ok - the shim routes at most once even when the credential re-resolves gh from PATH
ok - fm-gh.sh runs both the unconfigured and configured paths under bash 3.2
ok - the installer creates, verifies, reports precedence for, and removes the shim
ok - the installer refuses to overwrite or remove a gh it does not own
ok - the installer refuses a foreign gh symlink and leaves it intact
```
