# Azure DevOps pull request watch and completion verification

Empirical record for the merge watch, the completion path, and the landed proof on Azure DevOps Services, alongside the GitLab and Forgejo records ([`docs/gitlab-merge-watch.md`](gitlab-merge-watch.md), [`docs/forgejo-tea-integration.md`](forgejo-tea-integration.md)).
Every finding here was verified against a real Azure DevOps Services organization rather than assumed from `az --help`, and the one that is not is listed under "Not verified".
All evidence below was collected on 2026-10-23.
Organization, project, and repository names are redacted to `<org>`, `<Project%20Name>` (a project whose name contains a space, which the URL percent-encodes), and `<repo>`.
The completion test ran between two throwaway personal branches of one repository, with no reviewers, no work items, and no branch policy on the throwaway target, and both branches were deleted afterward.
A project opts in with the `forge=azure-devops` registry binding, which `bin/fm-project-mode.sh` owns; the watch and merge paths recorded here key off the pull request URL itself, and the binding decides only that a generated ship brief names `az repos pr` rather than `gh-axi`.

## Versions

```
$ az version -o json | jq -c '{"azure-cli": .["azure-cli"], "azure-devops": .extensions["azure-devops"]}'
{"azure-cli":"2.82.0","azure-devops":"1.0.2"}

$ jq --version
jq-1.7.1-apple

$ no-mistakes --version
no-mistakes version v1.84.0 (4822244) 2026-09-26T08:31:07Z

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin26)
```

## Pull request URLs

Azure DevOps Services serves a pull request at `https://dev.azure.com/<org>/<project>/_git/<repo>/pullrequest/<id>` and at `https://<org>.visualstudio.com/[DefaultCollection/]<project>/_git/<repo>/pullrequest/<id>`.
no-mistakes v1.84.0 reports the second form without `DefaultCollection`, escaping each segment with Go's `url.PathEscape`, while the `repository.webUrl` that `az repos pr show` prints keeps `DefaultCollection`, so `fm_pr_url_parse` in `bin/fm-pr-lib.sh` accepts both spellings as written.
A pull request id is unique per organization rather than per repository, so `az repos pr show --id <id> --organization <org-url>` resolves any id in the organization; every read therefore binds the answer to the URL's project and repository, which Azure DevOps compares case-insensitively.
`--detect false` keeps az from consulting a git remote in the current directory, so only the organization parsed from the URL is reached.

## Reading a pull request

The watch (`bin/fm-pr-poll.sh`), arming (`bin/fm-pr-check.sh`), the terminal-run detail (`bin/fm-crew-state.sh`), the merge path, and teardown all read one record:

```
$ az repos pr show --id <id> --organization https://<org>.visualstudio.com --detect false --only-show-errors --output json
```

Its `status` is `active`, `completed`, or `abandoned`; `isDraft`, `mergeStatus`, `lastMergeSourceCommit.commitId`, `lastMergeCommit.commitId`, `repository.id`, `repository.project.id`, and `completionOptions` are the fields the scripts act on.
`isDraft` is a JSON boolean, so a `false` reading must be kept as the text `false` rather than coalesced away: the first live completion attempt refused with `the draft state is unreadable` because the read used `(.isDraft // "")`, which jq evaluates to `""` for `false`.
The record of the completed test pull request read back as follows (summary of the `az repos pr show` JSON):

```
{
  "merge": "54343911d6f238a9f8550c0f65d0456eaee043fa",
  "reviewers": 0,
  "source": "f603dcfa36591139f36cf235493e62a24418135b",
  "status": "completed",
  "strategy": "squash",
  "title": "[test] Firstmate Azure DevOps lifecycle check - safe to ignore"
}
```

## Branch policies

`az repos pr policy list --id <id> --organization <org-url> --detect false --output json` lists the policy evaluations that apply to a pull request.
On the throwaway target it printed `[]`.
Read-only reads of active pull requests in other repositories showed blocking `Minimum number of reviewers`, `Required reviewers`, `Comment requirements`, `Status`, `Build`, and `Require a merge strategy` evaluations, plus optional builds and work item linking.
A `Require a merge strategy` evaluation reads `rejected` on an active pull request whose completion options name no strategy, so it is satisfied by the strategy sent at completion rather than by its status beforehand; `bin/fm-pr-merge.sh` therefore reads only its allowed strategies and never judges its status.

## Completing a pull request bound to a verified head

`az repos pr update --status completed` cannot bind a completion to a verified head, because `az repos pr update --help` lists no argument naming the source commit to complete.
The REST pull request update takes `lastMergeSourceCommit`, so the test sent the completion below, which names the first source commit, after a second commit had been pushed to the source branch:

```
{"status":"completed","lastMergeSourceCommit":{"commitId":"8d08a9bc2bd0a2373bd23fa07186ea6843d2c732"},"completionOptions":{"bypassPolicy":false,"deleteSourceBranch":false,"mergeStrategy":"squash"}}
```

`az devops invoke` refuses a PATCH of the `pullRequests` resource outright:

```
$ az devops invoke --organization https://<org>.visualstudio.com --detect false --area git --resource pullRequests --api-version 7.1 --route-parameters project=<project-id> repositoryId=<repo-id> pullRequestId=<id> --http-method PATCH --in-file stale.json --only-show-errors --output json
ERROR: The requested resource does not support http method 'PATCH'.
```

`az rest` on the repository-scoped route, with the Azure DevOps resource id so az requests a token for it, accepts the PATCH, and Azure DevOps refused the stale completion while the pull request stayed active:

```
$ az rest --method patch --url "https://<org>.visualstudio.com/<project-id>/_apis/git/repositories/<repo-id>/pullrequests/<id>?api-version=7.1" --resource 499b84ac-1321-427f-aa17-267ca6975798 --headers Content-Type=application/json --body @stale.json
ERROR: Conflict({"$id":"1","innerException":null,"message":"TF401192: The source branch has been modified since the last merge attempt.","typeName":"Microsoft.TeamFoundation.Git.Server.GitPullRequestStaleException, Microsoft.TeamFoundation.Git.Server","typeKey":"GitPullRequestStaleException","errorCode":0,"eventId":3000})
```

The same route with the current head completed the pull request through `bin/fm-pr-merge.sh`:

```
$ bin/fm-pr-merge.sh <task> https://<org>.visualstudio.com/<Project%20Name>/_git/<repo>/pullrequest/<id> -- --squash
armed: state/<task>.check.sh
verified: https://<org>.visualstudio.com/<Project%20Name>/_git/<repo>/pullrequest/<id> is active and mergeable, with every branch policy passing at head f603dcfa36591139f36cf235493e62a24418135b
verified: https://<org>.visualstudio.com/<Project%20Name>/_git/<repo>/pullrequest/<id> is completed from head f603dcfa36591139f36cf235493e62a24418135b
```

`az rest` authenticates with the az login token, so completing needs `az login` to an account that can reach the organization.

## Watch and landed proof

While the pull request was active the armed poll printed nothing, and after the completion it printed `merged` for both the URL form without `DefaultCollection` and the form with it.
Teardown proves an Azure DevOps task landed from the completed record: `status` `completed` with a `lastMergeCommit`, and the worker's commits contained in `lastMergeSourceCommit`, which still holds after a squash completion leaves the source branch's own commits off the target.
With a later local commit that was never in the pull request, teardown refused:

```
REFUSED: worktree <lab>/wt has work not on any remote and not landed.
unpushed commits:
4fc4b526 later local commit not in the pull request
f603dcfa [test] second throwaway commit for the head-binding check
8d08a9bc [test] Firstmate Azure DevOps lifecycle check - safe to ignore
```

and without it, teardown passed the landed check through the same record.
tasks-axi accepts only a GitHub or Forgejo pull request as a `--pr` link, so the closed backlog item records the URL as a note:

```
  state: done
  links: none
  body: "Azure DevOps pull request https://<org>.visualstudio.com/<Project%20Name>/_git/<repo>/pullrequest/<id>"
```

## Review diff

Azure DevOps serves no `refs/pull/<id>/head`; an active pull request has only `refs/pull/<id>/merge`, its merge preview, and a shallow fetch of one showed the target branch as its first parent and the pull request's source commit as its second.
That source commit is the one Azure DevOps last computed the merge from, so it lags a push until the merge is recomputed and stays behind for as long as a pushed commit conflicts with the target.
`bin/fm-review-diff.sh` therefore never reviews the preview: an Azure DevOps task diffs the local branch under the same `PR head unavailable` warning a GitLab merge request or a Gerrit change takes.

## Not verified

- A completion against a target with blocking branch policies: the throwaway target had none, so the policy verdicts in `bin/fm-pr-merge.sh` rest on the read-only policy evaluations above and on the hermetic tests in `tests/fm-pr-merge.test.sh`.
- Reading or completing with only a personal access token (`AZURE_DEVOPS_EXT_PAT`) and no `az login`.
- A pull request with more policy evaluations than `az repos pr policy list` returns in one response.
