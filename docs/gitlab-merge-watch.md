# GitLab merge request watch and merge verification

Empirical record for the merge watch and the merge path on GitLab, alongside the existing GitHub ones.
The arming, poll, and missing-`glab` evidence through the GitHub-unaffected case was collected on 2026-07-21; "Merging a merge request" was first run on 2026-08-22 and its two absent-pipeline refusals were re-run on 2026-09-09 after that refusal was reworded.
"Legacy instances with no route separator" was collected on 2026-09-09.
Every output is reproduced exactly.

## Versions

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

The merge evidence dated 2026-08-22 was collected on a different host, on:

```
$ glab --version
glab 1.82.0-<local build tag> (<local build commit>)

$ jq --version
jq-1.8.1

$ bash --version | head -1
GNU bash, version 5.2.15(1)-release (x86_64-amazon-linux-gnu)
```

That `glab` is a locally built 1.82.0; only its build tag and commit are elided, because they name a private build rather than a released version.

The 2026-09-09 evidence was collected on macOS 26.6.2, on:

```
$ glab --version
glab 1.116.0 (e8436ca8a)

$ jq --version
jq-1.7.1-apple

$ bash --version | head -1
GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
```

That `bash` is the system one macOS ships, so the same evidence also shows the parser and the poll running on bash 3.2 rather than only on a 5.x build.

## The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

## Why the host is data rather than a constant

GitLab runs mostly on self-hosted instances, so a merge request can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number`, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
`tests/fm-pr-check-security.test.sh` proves the host-agnostic path through a non-default-host sidecar and verifies that `glab` receives the reconstructed project URL.

## How plain glab is invoked, and why

Two things about plain `glab` were established by running it, because assuming either one would have failed silently into a permanent "not merged".

First, plain `glab` has no field selector.
`gh` reads one field with `--json state -q .state`; `glab mr view` offers only `-F, --output string  Format output as: text, json`.
Its JSON would need a JSON processor, and `jq` is not one of firstmate's common tools, so the state is read from glab's own field output instead.
Only an exact `merged` wakes firstmate, so a changed output format produces no wake rather than a false merge.

Second, `glab` cannot take a merge request URL the way `gh pr view` can.
That form shells out to git for the current repository, and the watcher runs in no repository:

```
$ cd /tmp && glab mr view https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
fatal: not a git repository (or any parent up to mount point /)
Stopping at filesystem boundary (GIT_DISCOVERY_ACROSS_FILESYSTEM not set).
git: exit status 128
```

Passing the project URL to `-R` with the merge request number works from anywhere, and resolves the instance from that URL rather than from glab's configured default:

```
$ cd /tmp && glab mr view 1 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture
title:	Add the merged example file
state:	merged
author:	KarotKris
labels:	
assignees:	
reviewers:	
comments:	0
number:	1
url:	https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
--
This merge request is the merged half of the fixture. It is merged on purpose, so that reading its state returns merged.

$ cd /tmp && glab mr view 2 -R https://gitlab.com/KarotKris/gitlab-merge-watch-fixture | sed -n 's/^state:[[:space:]]*//p'
open
```

## End to end: arming and polling a real merge request

Three tasks were armed, two against the fixture and one against the placeholder host:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://gitlab.example/group/subgroup/project/-/merge_requests/7
armed: state/e3.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
gitlab.com
KarotKris/gitlab-merge-watch-fixture
1

$ cat state/e3.pr-poll
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
```

The provenance record for the non-default host, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://gitlab.example/group/subgroup/project/-/merge_requests/7
gitlab.example
group/subgroup/project
7
514b7e04f0cca3e2c913c9fd504c54dfe54c8a51a7f5ebc57279bbd4db5d4a60
1817b0f95db7148246434a4afa0b2c8e7b81fd8f74ef7d473bbd62023e47c439
70:957243
70:957244
```

Running each published poll the way the watcher does, where an empty result means the poll stayed silent and produced no wake:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e2.pr-poll)
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

The merged fixture merge request produces exactly one `merged` line.
The open one produces nothing, and the unreachable placeholder host produces nothing rather than a false merge.

The same bytes work in the watcher's sidecar-driven mode, where the published check locates its own record:

```
$ state/e1x.check.sh
merged
```

## A missing CLI produces no wake, never a false merge

The poll is silent on every error by design, so a missing `glab` would otherwise be indistinguishable from a merge request that is never merged.
With `glab` removed from `PATH`, the poll stays silent even for the merge request that is genuinely merged:

```
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
$ PATH="$noglab" fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e3.pr-poll)
```

Arming is the one point where that can be reported, so it refuses there instead of arming a watch that can never fire:

```
$ PATH="$noglab" fm-pr-check.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
error: watching a GitLab merge request requires glab on PATH
$ echo $?
1
```

A GitHub task is unaffected by a missing `glab`:

```
$ PATH="$noglab" fm-pr-check.sh e6 https://github.com/kunchenguid/firstmate/pull/750
armed: state/e6.check.sh
```

## Registration version

The live registration tag is `fm-pr-poll-registration-v2`, which includes the provider tag.
A `fm-pr-poll-registration-v1` record no longer parses.
Arm a current watch with `bin/fm-pr-check.sh`.

## Legacy instances with no route separator

GitLab introduced the reserved `-` route separator in 12.0.
An instance older than that has no `/-/` route at all: its merge requests live directly under the project path, and its own web UI links `https://<host>/<path>/merge_requests/<n>`.
Before 2026-09-09 that spelling was refused as `error: invalid PR check request`, so such an instance could not be armed, polled, or addressed at all.

The evidence below was read from a private GitLab 11.8.1 instance, read-only: nothing was created, merged, or written there, and the only calls that reached it were `GET` reads and `glab mr view`.
Its host and namespace are replaced throughout by `gitlab.example/group/project`; nothing else is altered.

The instance version, and what its merge request API actually returns:

```
$ curl -sS -H "PRIVATE-TOKEN: <token>" https://gitlab.example/api/v4/version
{"version":"11.8.1","revision":"657d508"}

$ curl -sS -H "PRIVATE-TOKEN: <token>" \
    https://gitlab.example/api/v4/projects/group%2Fproject/merge_requests/29 \
  | jq '{state, merge_status, detailed_merge_status, has_conflicts, blocking_discussions_resolved, head_pipeline, sha, web_url}'
{
  "state": "merged",
  "merge_status": "can_be_merged",
  "detailed_merge_status": null,
  "has_conflicts": null,
  "blocking_discussions_resolved": null,
  "head_pipeline": null,
  "sha": "ea04ad94d0f9dbaa5681275136ec4cc61a6aa23e",
  "web_url": "https://gitlab.example/group/project/merge_requests/29"
}
```

`detailed_merge_status`, `has_conflicts`, `blocking_discussions_resolved`, and `head_pipeline` are not keys of that response at all; `jq` prints an absent key as `null`.
`web_url` is the instance's own canonical spelling of the merge request, and it carries no separator, which is why the parser has to accept that form rather than rewrite it.

The same merge request through `glab`, which is what the poll and the merge path actually read:

```
$ glab mr view 29 -R https://gitlab.example/group/project | sed -n 's/^state:[[:space:]]*//p'
merged

$ glab mr view 29 -R https://gitlab.example/group/project -F json \
  | jq '{detailed_merge_status, has_conflicts, blocking_discussions_resolved, head_pipeline}'
{
  "detailed_merge_status": "",
  "has_conflicts": false,
  "blocking_discussions_resolved": false,
  "head_pipeline": null
}
```

The field output the poll reads is correct on this instance, so the watch works once the URL is accepted.
The JSON the merge path reads is the reason the merge path cannot simply trust it: `glab` deserializes a field the instance never sent into its type's default, so `"has_conflicts": false` and `"blocking_discussions_resolved": false` above are not answers, and are indistinguishable from real ones.
The empty `detailed_merge_status` is what identifies that situation, because GitLab only added that field in 15.6.

Arming, the stored record, and the poll, against that instance:

```
$ fm-pr-check.sh e1 https://gitlab.example/group/project/merge_requests/29
armed: state/e1.check.sh

$ cat state/e1.pr-poll
gitlab
https://gitlab.example/group/project/merge_requests/29
gitlab.example
group/project
29

$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/e1.pr-poll)
merged
```

That merge request had been merged by hand in the GitLab web UI, so this is also the manual-merge case: firstmate recognises a merge it did not perform, on an instance it cannot merge on.
The stored URL is kept exactly as given, and the poll rebuilds both canonical spellings and requires the stored URL to equal one of them.
The two can never both match, because a `-` path segment is refused, so the identity still determines the URL exactly and a doctored record cannot redirect the poll.

The merge path reaches the same instance from that URL and refuses it, naming both absences as themselves:

```
$ fm-pr-merge.sh e1 https://gitlab.example/group/project/merge_requests/29
armed: state/e1.check.sh
error: refusing to merge https://gitlab.example/group/project/merge_requests/29
  - state is "merged", not open
  - this GitLab reported no detailed_merge_status, so mergeability could not be read; an instance older than GitLab 15.6 has no such field, and the has_conflicts and blocking_discussions_resolved values reported alongside it cannot be told apart from unset defaults
  - there is no CI pipeline for this merge request: GitLab reports no pipeline at head ea04ad94d0f9dbaa5681275136ec4cc61a6aa23e, which is an absent check rather than a passing one, so a project that runs no CI cannot satisfy this condition
$ echo $?
1
```

No merge was attempted: the refusal happens before `glab mr merge` is reached, and the run's `glab` calls were `mr view` only.
An instance with no CI therefore remains unmergeable through this path, exactly as the fixture project above is.
Accepting the legacy route changes what can be watched and addressed; it does not change what can be merged, and no absent check has become a pass.

## Merging a merge request

`bin/fm-pr-merge.sh` now merges a GitLab merge request through the shared recording helper and GitLab's own live pre-merge guards.
Every run below used a throwaway `FM_HOME`, so no live task record was touched, and a `glab` wrapper that refused any `merge` subcommand outright, so no merge could reach the forge even if a check were wrong.
That wrapper is why the open fixture merge request could be used as evidence at all: it is `mergeable` with discussions resolved, so the pipeline conditions are the only thing between it and a real merge.

Merging needs `glab` for the read and `jq` to parse it, and either one absent refuses before anything is recorded:

```
$ PATH="$noglab" fm-pr-merge.sh e5 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
error: merging a GitLab merge request requires glab on PATH
$ echo $?
1
$ PATH="$nojq" fm-pr-merge.sh e6 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
error: merging a GitLab merge request requires jq on PATH
$ echo $?
1
```

Neither refusal armed a poll or recorded a `pr=`, so a missing tool leaves no half-prepared merge behind.

`jq` is not one of firstmate's common tools, which is why the watch poll reads glab's field output instead.
The merge path cannot do the same: `detailed_merge_status`, `has_conflicts`, `blocking_discussions_resolved`, and the head pipeline appear only in glab's JSON.
The poll's silence on a missing tool is safe because silence means "not merged yet"; a merge cannot be silent about it, so the requirement is reported rather than assumed.

The merged half of the fixture is refused, and every failing condition is listed rather than just the first (re-run 2026-09-09):

```
$ fm-pr-merge.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
  - state is "merged", not open
  - detailed_merge_status is "not_open", not mergeable
  - there is no CI pipeline for this merge request: GitLab reports no pipeline at head 33762fcf6777c8d993220d25fb541e56c48081b9, which is an absent check rather than a passing one, so a project that runs no CI cannot satisfy this condition
$ echo $?
1
```

The open half is `mergeable`, conflict-free, and has its discussions resolved, so only the pipeline condition refuses it.
The fixture runs no CI, so its `head_pipeline` is `null`, and that absence is reported as absent CI rather than as an unreadable or failing status (re-run 2026-09-09):

```
$ fm-pr-merge.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - there is no CI pipeline for this merge request: GitLab reports no pipeline at head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8, which is an absent check rather than a passing one, so a project that runs no CI cannot satisfy this condition
$ echo $?
1
```

A project that runs no pipeline at all therefore cannot merge through this path.
That is the intended reading of the requirement rather than an oversight: a successful pipeline at the head is a condition, and "there is no pipeline" does not satisfy it.
Saying so in those words is the point of the wording: an operator reading it learns that the project has no CI, which is a different fact from a pipeline that ran and failed, and neither one is a pass.
A pipeline that ran and did not pass keeps its own `the head pipeline status is "<status>", not success` line, and `tests/fm-pr-merge.test.sh` drives the two apart so neither can be reported as the other.

Both refusals came after `pr=` was recorded and the merge poll was armed, exactly as a failing `gh-axi pr merge` does on the GitHub side, so a refusal still leaves the audit trail and the watch in place.

A recorded `pr_head=` that no longer matches the live head is reported, and the live head is what gets verified.
The stale value below was written into the task record by hand, because a GitLab task never records one on its own (re-run 2026-09-09):

```
$ fm-pr-merge.sh e4 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e4.check.sh
notice: recorded head 1111111111111111111111111111111111111111 disagrees with the live head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8; verifying the live head
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - there is no CI pipeline for this merge request: GitLab reports no pipeline at head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8, which is an absent check rather than a passing one, so a project that runs no CI cannot satisfy this condition
```

The remaining refusal conditions, and the merge itself, are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The conflict, unresolved-discussion, and running-pipeline conditions were additionally exercised against real merge requests on a private instance; those runs cannot be reproduced here, so their identifiers stay out of this record.
The merge itself is not exercised against any live merge request, in either direction: `glab mr merge` has no dry run, so a live success path would mean merging someone's work to produce evidence.

## Why the head is read live and bound to the merge

The verified head is passed to `glab mr merge --sha`, so GitLab refuses the merge if the source branch moved between the read and the merge.
Without it, a push landing in that window would merge commits nothing verified.

`--yes` is passed for the same reason the watch poll needs no terminal: an unattended run cannot answer a confirmation prompt, and a wedged prompt is worse than a refusal.
It skips only that prompt; the conditions above are what authorize the merge.

## Why a recorded head is not the authority

`bin/fm-pr-check.sh` records `pr_head=` only for GitHub, where `gh` exposes the head commit as a selectable field.
It is optional by design, and the other consumers already treat it that way: `bin/fm-teardown.sh` reads the head from the forge at teardown and falls back to its provider-agnostic content check, and `bin/fm-review-diff.sh` resolves the head from the remote when none is recorded.

The merge path does not record one either, and deliberately does not depend on one.
A rebase moves the head and leaves any recorded value stale, so a merge decided from metadata can verify a commit that no longer exists.
Reading the head live at merge time, reporting a recorded value that disagrees, and binding the merge to what was actually verified is what closes that gap.
