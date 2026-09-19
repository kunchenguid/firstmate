# Azure DevOps pull request merge watch

Empirical record for the merge watch on Azure DevOps, alongside the existing GitHub and GitLab ones.
The `az` contract facts below were collected on 2026-09-18, and every output is reproduced exactly.

## Versions

```
$ az version
{
  "azure-cli": "2.86.0",
  "azure-cli-core": "2.86.0",
  "azure-cli-telemetry": "1.1.0",
  "extensions": {
    "account": "0.2.5",
    "azure-devops": "1.0.6",
    "resource-graph": "2.1.1"
  }
}

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## Why no live organisation appears here

The GitHub and GitLab records read public fixtures, so a reader can rerun each command and see the same output.
Azure DevOps has no equivalent: every organisation reachable from this fleet is private, and naming one here would put a private estate's organisation, project, and repository into a tracked file.
So this record proves the `az` contract the poll depends on with commands that need no organisation, and leaves the rest to `tests/fm-pr-check-security.test.sh`, which exercises arming, the merged and abandoned readings, retirement, and every refusal against a fixture `az` that reproduces the contract established below.

## Why the organisation is data rather than a constant

Azure DevOps runs on `dev.azure.com` and on server installs, so a pull request can live under any host.
Its project path is `<organisation>/<project>/_git/<repository>`, or `<organisation>/_git/<repository>` when the repository carries its project's own name, so no owner-and-repository pair addresses one the way it does on GitHub.
The stored record therefore carries the same `provider`, `url`, `host`, `path`, and `number` as the other forges, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
The organisation is re-derived from the first path segment rather than stored separately, so the sidecar layout is unchanged and the third forge needed no new field.

## The URL shape that is accepted

A project or repository name reaches the URL percent-encoded, which is why `Deal%20Mechanic` is a canonical segment rather than a mangled one.
An escape must be well formed, and the decoded name must not contain a slash, a backslash, a control character, or a surrounding space, each of which would name a different thing than the URL appears to.
A `%00` escape is refused where it is still visible, because a decoded NUL cannot survive inside a shell string to be caught afterwards.

A URL carrying a query string, a fragment, a trailing slash, or the `pullRequest` spelling the browser sometimes shows is refused rather than silently normalised, so exactly one spelling addresses one pull request.
The legacy `<organisation>.visualstudio.com` form is refused for the same reason: its organisation is not a path segment, so it would need a second addressing rule.
`bin/fm-pr-check.sh` reports every one of those as `error: invalid PR check request`.

## How az is invoked, and why

Three things about `az` were established by running it, because assuming any of them would have failed silently into a permanent "not merged".

First, `az repos pr show` takes an organisation-wide pull request id and no repository:

```
$ az repos pr show --help
...
Arguments
    --id      [Required] : ID of the pull request.
    --detect             : Automatically detect organization.  Allowed values: false, true.
    --open               : Open the pull request in your web browser.
    --org --organization : Azure DevOps organization URL. You can configure the default organization
                           using az devops configure -d organization=ORG_URL. Required if not
                           configured as default or picked up via git config. Example:
                           `https://dev.azure.com/MyOrganizationName/`.
```

The organisation therefore comes from the validated record, and `--detect false` keeps `az` from reaching for a git repository the watcher does not have.
Because the id alone can name a pull request in any repository of that organisation, the poll binds the answer to the repository the URL names by also reading `repository.name` and comparing it, case-insensitively, against the decoded repository segment.
That is the Azure DevOps equivalent of scoping `glab` with `-R <project URL>`.

Second, a JMESPath list rendered with `-o tsv` puts one value per line rather than one tab-separated row, and a JSON null renders as the literal `None`:

```
$ az cloud show --only-show-errors --query "[name, suffixes.storageEndpoint, suffixes.nosuchfield]" -o tsv | cat -A
AzureCloud$
core.windows.net$
None$
```

`az cloud show` is used here because it needs no credential and no organisation; the formatter it exercises is the same one `az repos pr show` uses.
The poll reads the three values as three lines for that reason.
`None` cannot be mistaken for a merge commit, because only a 40- or 64-character hexadecimal value is accepted as one.

Third, the azure-devops extension is what supplies `az repos` at all, and it answers locally:

```
$ az extension show --name azure-devops --output tsv --query name
azure-devops
$ echo $?
0
$ az extension show --name nosuchext --output tsv --query name
$ echo $?
1
```

## The landed reading

`status` is `completed` with a `lastMergeCommit` when the pull request has landed, and `abandoned` when it was closed without landing.
The poll emits its single `merged` line only for `completed` together with a merge commit that is a real hexadecimal object name and a repository name that matches the URL.
Every other reading is silent: `active`, `abandoned`, a completed pull request with no merge commit, a changed output format, an unreadable pull request, an absent `az`, and an absent extension all produce no wake rather than a false merge.

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `az` would otherwise be indistinguishable from a pull request that is never completed.
Arming is the one point where that can be reported, so `bin/fm-pr-check.sh` refuses there instead of arming a watch that can never fire, with `error: watching an Azure DevOps pull request requires az on PATH`.
An `az` without the azure-devops extension can never answer `az repos` either, and is refused at arming for the same reason with `error: watching an Azure DevOps pull request requires the az azure-devops extension`.
A GitHub or GitLab task is unaffected by either absence.

## Merging is not part of this path

`bin/fm-pr-merge.sh` refuses an Azure DevOps pull request before any side effect, so nothing is recorded and no poll is armed by a mistaken call.
Those pull requests are landed in Azure DevOps itself, and the armed watch is what reports the merge when it happens.

## Registration version

The registration tag is unchanged at `fm-pr-poll-registration-v2`: the third forge reuses the provider-tagged identity that tag already covers.
Arm a current watch with `bin/fm-pr-check.sh`.
