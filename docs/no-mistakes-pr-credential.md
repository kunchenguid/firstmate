# Routing no-mistakes GitHub calls through firstmate's gh shim

The no-mistakes pipeline's PR step opens pull requests by shelling out to `gh`.
When the environment that reaches it exports a GitHub fine-grained personal access token, `gh pr create` fails with "Resource not accessible by personal access token", because GitHub forbids that token class from the GraphQL `createPullRequest` mutation.
Ordinary REST calls with the same token succeed, so the failure looks selective and shows up only at the end of an otherwise green pipeline run.

The same fine-grained token can also receive a 403 from the check-runs API behind `gh pr checks` while retaining read access to the workflow-runs API.
Without a fallback, no-mistakes treats every poll as an unreadable CI state and can wait until its timeout even after the exact PR head's workflows have completed.

This page owns the mechanism firstmate uses to put a PR-capable credential in front of PR mutations while keeping CI reads least-privilege, why that mechanism was chosen over the alternatives, and what its limits are.
`bin/fm-gh.sh`, `bin/fm-gh-shim.sh`, `bin/fm-gh-ci-fallback.sh`, and `bin/fm-gh-shim-install.sh` own their exact flags and behavior in their own headers.

## What no-mistakes supports today

The interception surface was read directly from the tool rather than inferred.
The evidence below comes from the installed binary at v1.41.2 and the upstream source at release 1.46.0, commit `20892e6`, which agree on every point that matters here.

- The pipeline runs nine steps in order: `intent`, `rebase`, `review`, `test`, `document`, `lint`, `push`, `pr`, `ci`.
- The `pr` step runs inside the no-mistakes daemon, not in the task worktree, and reaches GitHub through `internal/scm/github`, which builds `gh` command vectors and executes them by the bare name `gh`.
- The repository registration stores `working_path`, `upstream_url`, and optional `fork_url` in the no-mistakes state database.
  `Repo.PushURL()` is the pipeline's canonical delivery-target rule: use `fork_url` when configured, otherwise use `upstream_url`.
  The push step follows that rule even though the bare gate repository's own `origin` is initialized from the upstream URL.
- The `ci` step reaches GitHub through the same bare `gh` path and polls `gh pr checks <number-or-url> --repo <owner/repo> --json name,state,bucket,completedAt` in v1.41.2, with `link` added to that field set in current upstream releases.
- Neither the global `~/.no-mistakes/config.yaml` nor the per-repo `.no-mistakes.yaml` exposes a GitHub credential, a `gh` binary path, or a PR-step command override.
  `agent_path_override` overrides agent binaries only, and `commands.*` covers lint, test, and format commands rather than the forge calls.
- Bitbucket Cloud credentials, by contrast, come from named environment variables the operator controls: `NO_MISTAKES_BITBUCKET_EMAIL`, `NO_MISTAKES_BITBUCKET_API_TOKEN`, and `NO_MISTAKES_BITBUCKET_API_BASE_URL`.
  GitHub has no equivalent, which is the asymmetry the upstream proposal targets.
- The daemon resolves its environment once from the login shell at startup and caches it, so the ambient GitHub token variables and `PATH` the PR step sees are whatever that login shell exported when the daemon started.

The step-execution layer does already contain a first-class interception seam.
`stepCmd` in `internal/pipeline/steps/common_exec.go` resolves a command against a step-scoped `PATH` and passes a step-scoped environment whenever `StepContext.Env` is populated.
That field is declared in `internal/pipeline/pipeline.go` as "extra environment variables for subprocesses (used in tests)", and the production executor never sets it.
The mechanism exists; only a supported way to populate it from configuration is missing.
[`proposals/nm-pr-step-interception.md`](proposals/nm-pr-step-interception.md) is the upstream proposal to close exactly that gap.

## The mechanism firstmate uses

Because no supported configuration seam exists, firstmate intercepts `gh` on the `PATH` the daemon resolves, and does it with an explicitly installed shim.

- `bin/fm-gh.sh` runs one command with this home's PR-capable credential injected, reading the command prefix from `config/gh-credential`.
  When configured, it removes ambient `GH_TOKEN` and `GITHUB_TOKEN` before starting that prefix because `gh` gives `GH_TOKEN` precedence, so a daemon's inherited token cannot override the injected credential.
  With no such file it execs the command unchanged, so an unconfigured home behaves exactly as before.
  A credential prefix may execute its trailing command once; recursive wrapper entry fails with exit 70 and names the invalid prefix contract.
- `bin/fm-gh-shim.sh` is installed as a symlink named `gh`.
  It routes `gh pr create` and `gh pr edit` through `fm-gh.sh`.
  On either credential-routed mutation, a caller-supplied `--repo` or `-R` wins unchanged.
  Otherwise, the shim identifies the current `repos/<id>.git` gate, reads that exact repository's no-mistakes registration, applies the same fork-first rule as `Repo.PushURL()`, and appends the resulting GitHub `owner/name` as `--repo <owner/name>` before invoking `gh`.
  The registered checkout's `no-mistakes` remote must point back to the same gate and one of its GitHub remotes must corroborate the selected target.
  A missing registration, unavailable checkout, gate mismatch, contradictory remote, malformed URL, non-GitHub URL, or unavailable `sqlite3` refuses the mutation with a repair-oriented diagnostic rather than letting `gh` infer a repository.
  The shim never rewrites the gate's remotes and never selects a target from remote ordering, account identity, or the gate's upstream relationship.
  It sends only no-mistakes' JSON `gh pr checks` shape through the bounded CI fallback, and execs the real `gh` directly for every other call.
  Credential routing may re-enter the shim once when a valid prefix resolves `gh` from `PATH`; a third shim entry fails with exit 70 and identifies the credential or installed-target loop.
- `bin/fm-gh-ci-fallback.sh` first runs the real `gh pr checks` with the ambient narrow token.
  Only the personal-token denial whose GraphQL error path names a `statusCheckRollup` component, at whatever depth GitHub currently reports it, causes it to resolve the PR's exact head SHA and read every workflow run filtered by that SHA with the same token; it never calls `fm-gh.sh` or exposes `config/gh-credential` to CI reads.
  The fallback also paginates the repository's active-workflow inventory with that token and requires one unambiguous latest run for every active workflow.
  A run counts only when the response binds it to the exact repository, current PR number, and current PR head SHA.
  The latest published attempt of one run supersedes older attempts, while conflicting latest attempts, equally current runs, missing active workflows, wrong-head runs, and workflows unrelated to the PR remain non-green.
  For a workflow that reports success, the fallback paginates that run's jobs with `filter=all`, retains only jobs from the selected latest attempt and exact head, and requires every returned job to complete successfully.
  A missing job set or an unexpectedly skipped, cancelled, pending, or failed job therefore cannot hide behind workflow-level success.
  Successful, failed, cancelled, skipped, and pending workflow conclusions are returned in the JSON check shape no-mistakes already consumes.
  A readable concrete API or head-drift failure becomes a typed failed check, so no-mistakes cannot turn the known fallback path back into an indefinitely repeated unreadable-command warning.
- The GitHub merge boundary resolves the genuine `gh` binary itself, so its raw GraphQL capture remains valid when a same-home or current foreign-home shim is installed on `PATH`.
  A side-effect-free identity probe lets it skip current shims independent of their home path.
  The generated capture wrapper independently stops a stale, unrecognized, or mid-update executable that re-enters `PATH`, preserving exit 70 rather than allowing a wrapper-shim process tree to grow.
  The merge operator's repository-lock handoff is also depth-bound to its one intentional child entry, so losing or contradicting that lock across a mid-flight home update fails before merge verification or mutation.
- `bin/fm-gh-shim-install.sh` installs, removes, and verifies that symlink, and reports whether the install directory actually precedes the real `gh` on the evaluated `PATH`.

Nothing installs the shim automatically.
Installation changes how every process using that `PATH` resolves `gh`, so it stays a deliberate act.

No spawn or brief plumbing carries this to crewmates, and none is needed.
Interception happens where the PR step actually runs, in the daemon, so once the shim is installed every pipeline run on this machine uses it without any per-task wiring.
[`verification/gh-pr-credential.md`](verification/gh-pr-credential.md) records the evidence behind the claims on this page.

### Setup

Write the credential prefix into `config/gh-credential`, then install the shim into a directory that precedes the real `gh` on the daemon's `PATH` and confirm it wins.
`docs/configuration.md` owns the configuration file's schema.

```
bin/fm-gh.sh --check
bin/fm-gh-shim-install.sh --install --dir <dir-on-path>
bin/fm-gh-shim-install.sh --check --dir <dir-on-path>
```

Run the check from a login shell.
The daemon resolves its environment from the login shell, so a precedence verdict from an unusual shell can differ from what the daemon actually has.
The credential route also requires `sqlite3` on that resolved `PATH`, because the no-mistakes repository registration is the target authority.
Pending, missing, or ambiguous fallback evidence has a one-hour deadline by default.
`FM_GH_CI_MAX_PENDING_SECONDS` changes that deadline, and `FM_GH_CI_STATE_ROOT` changes the machine-local deadline record root whose default is `$XDG_STATE_HOME/firstmate/gh-ci-fallback`.
`FM_GH_CI_ACTIONS_ONLY_REPOS` is a comma-separated allowlist of exact `owner/repository` names whose required merge evidence is explicitly known to come entirely from GitHub Actions.
An otherwise green fallback result becomes a typed terminal failure unless its repository is present in that allowlist.
The script header owns the exact environment and state mechanics.

## Limits worth knowing before installing

The shim is scoped to a `PATH`, never to a repository, a task, or a worktree.
A worktree-scoped shim is not possible: the PR step executes in the daemon process, whose environment is fixed at daemon startup, so nothing placed inside a task worktree is on the `PATH` that resolves `gh`.
Every process that resolves `gh` through the install directory is therefore affected, including interactive shells and unrelated tools.
The shim keeps that blast radius bounded by changing only `pr create`, `pr edit`, and the exact JSON `pr checks` shapes no-mistakes uses.
An implicit repository target for `pr create` or `pr edit` is accepted only from a registered no-mistakes gate checkout; callers elsewhere must pass `--repo` or `-R` explicitly.
Interactive `pr checks` output, every failure outside that `statusCheckRollup` permission denial, and every other invocation remain the real `gh` behavior.
The fallback can observe GitHub Actions workflow runs only; it is not equivalent to readable check-runs for repositories whose merge gate depends on a third-party check provider.
The narrow credential also cannot read branch-protection required-check configuration or repository rulesets on the verified private repository.
The fallback therefore uses every active Actions workflow as a conservative required set, never infers that an absent active workflow is optional, and requires the repository-level Actions-only authority before reporting green.
This preserves fail-closed required-check semantics, but a repository with active scheduled, dispatch-only, deployment, or other non-PR workflows cannot reach green through the fallback until the credential boundary or upstream monitor supplies an exact readable required-workflow set.

The daemon caches the `PATH` value it captured at startup, but `PATH` directories are scanned at exec time and `fm-gh.sh` reads `config/gh-credential` on every routed invocation.
Installing the shim into a directory already present on the daemon's cached `PATH`, or changing the credential file, therefore takes effect on the next `gh` call; changing the `PATH` value itself requires a newly started daemon.

## Alternatives considered

- **Export the classic PR-capable token to every crew or the no-mistakes daemon.**
  That would make check-runs readable, but it would expose a broader credential to every command and subprocess even though the narrow token can already read workflow runs.
  This was rejected in favor of least privilege.
- **Keep the narrow token and translate a forbidden check-runs read into exact-head workflow runs.**
  This is the chosen CI path because it adds no credential surface, activates only for the known authorization failure, and cannot certify a branch name, stale head, unrelated run, missing active workflow, or superseded attempt.
- **Skip the PR step** with `no-mistakes axi run --skip pr` and open the PR separately.
  This uses a supported flag, but it gives up the step's own behavior, and the CI step monitors the pull request the pipeline created, so the run also stops producing the "checks green" outcome firstmate's `no-mistakes` delivery mode depends on.
- **Pre-create the pull request** so the step adopts it.
  The step does check for an existing open PR on the branch and updates it instead of creating one, which makes this genuinely supported.
  It is not usable as a general mechanism, because the branch only reaches the forge during the pipeline's own `push` step, which runs immediately before `pr`.
- **Change the login-shell environment** so the daemon resolves a PR-capable credential.
  This is the path upstream documents, and it needs no shim, but it is machine-global, it takes effect only after the daemon restarts, and it makes every repository's pipeline use one credential.

## What remains upstream

The shim is a local mitigation, not an upstream fix.
It intercepts commands the pipeline did not offer to let anyone configure, so no-mistakes cannot validate the interception itself.
The durable fix is a supported per-repository or global configuration knob that populates the step-scoped environment the executor already understands, described in [`proposals/nm-pr-step-interception.md`](proposals/nm-pr-step-interception.md).
That private upstream proposal also records the verified `statusCheckRollup` limitation and the fail-closed workflow-runs fallback needed by the CI monitor.
Retire each local route once no-mistakes ships its corresponding supported behavior.
