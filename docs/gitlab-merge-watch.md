# GitLab merge request watch and merge verification

Empirical record for the merge watch and the merge path on GitLab, alongside the existing GitHub ones.
The arming, poll, and missing-`glab` evidence through the GitHub-unaffected case was collected on 2026-07-21; "Merging a merge request" was run on 2026-08-22; the merge request head ref, the review and ready-record behavior built on it, and the pipeline provenance below were collected on 2026-10-09.
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

The 2026-10-09 evidence below ran `git ls-remote`, `curl`, and the firstmate scripts directly, on:

```
$ git --version
git version 2.56.0

$ jq --version
jq-1.8.1

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-redhat-linux-gnu)
```

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

## The merge request's own head ref

GitLab publishes each merge request's current head inside the project repository at `refs/merge-requests/<iid>/head`.
The ref is current while the merge request is open and it outlives the source branch, so reading the published head never depends on the source branch or on a local branch:

```
$ git ls-remote https://gitlab.com/KarotKris/gitlab-merge-watch-fixture.git "refs/merge-requests/2/*"
66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8	refs/merge-requests/2/head
4ee1baff65593d0091283b40533c3d87c8200584	refs/merge-requests/2/merge
```

That head is the merge request's own head commit, which the API reports as its `sha`:

```
$ curl -s "https://gitlab.com/api/v4/projects/KarotKris%2Fgitlab-merge-watch-fixture/merge_requests/2" | jq -r ".sha"
66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

The ref also outlives the source branch: the fixture's merged merge request no longer has its source branch, and its head ref still names that merge request's head:

```
$ git ls-remote https://gitlab.com/KarotKris/gitlab-merge-watch-fixture.git "refs/merge-requests/1/head" "refs/heads/merged-example"
33762fcf6777c8d993220d25fb541e56c48081b9	refs/merge-requests/1/head
$ curl -s "https://gitlab.com/api/v4/projects/KarotKris%2Fgitlab-merge-watch-fixture/merge_requests/1" | jq -r ".state, .source_branch, .sha"
merged
merged-example
33762fcf6777c8d993220d25fb541e56c48081b9
```

`bin/fm-review-diff.sh` fetches that ref exactly as it fetches `refs/pull/<n>/head` on GitHub, and `bin/fm-pr-check.sh` records its commit as `pr_head=` when a GitLab task is armed.
A review of the fixture's open merge request therefore shows the published change even when the worker copy's branch does not contain it:

```
$ fm-review-diff.sh proof --stat
diff base: origin/main
 open-example.txt | 2 ++
 1 file changed, 2 insertions(+)
```

The [review fallback contract](architecture.md#delivery-modes-are-explicit-per-task) applies when the published head cannot be fetched.
For this fixture, with neither a usable recorded head nor local changes, that fallback prints `warning: PR head unavailable; diff may lag the open PR (using local branch fm/proof)` and `no changes vs origin/main`.

Arming the same merge request records the published head rather than nothing:

```
$ fm-pr-check.sh ready https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/ready.check.sh
$ grep '^pr_head=' state/ready.meta
pr_head=66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
$ git ls-remote https://gitlab.com/KarotKris/gitlab-merge-watch-fixture.git "refs/merge-requests/2/head" | cut -f1
66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

The recorded value is the ref's own commit, read from the copy's project remote, so it names a head the forge holds.
It stays a fallback: a fetch that succeeds always outranks it, and the merge path never treats it as authority.

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

The merged half of the fixture is refused, and every failing condition is listed rather than just the first:

```
$ fm-pr-merge.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
  - state is "merged", not open
  - detailed_merge_status is "not_open", not mergeable
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 33762fcf6777c8d993220d25fb541e56c48081b9
$ echo $?
1
```

The open half is `mergeable`, conflict-free, and has its discussions resolved, so only the pipeline conditions refuse it.
The fixture runs no CI, so its `head_pipeline` is `null`, which is reported as `none` rather than treated as nothing to check:

```
$ fm-pr-merge.sh e2 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e2.check.sh
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
$ echo $?
1
```

A project that runs no pipeline at all therefore cannot merge through this path.
The [pipeline provenance requirements](#pipelines-that-run-on-a-merged-result) require a successful pipeline, so "there is no pipeline" does not satisfy them.

Both refusals came after `pr=` was recorded and the merge poll was armed, as a failed live verification or `gh pr merge` does on the GitHub side, so a refusal still leaves the audit trail and the watch in place.

A recorded `pr_head=` that no longer matches the live head is reported, and the live head is what gets verified.
The stale value below stands in for the one a rebase leaves behind:

```
$ fm-pr-merge.sh e4 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e4.check.sh
notice: recorded head 1111111111111111111111111111111111111111 disagrees with the live head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8; verifying the live head
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

The remaining refusal conditions, and the merge itself, are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The conflict, unresolved-discussion, and running-pipeline conditions were additionally exercised against real merge requests on a private instance; those runs cannot be reproduced here, so their identifiers stay out of this record.
The merge itself is not exercised against any live merge request, in either direction: `glab mr merge` has no dry run, so a live success path would mean merging someone's work to produce evidence.

## Pipelines that run on a merged result

Merged results pipelines and merge trains run the merge request's pipeline on a temporary merge commit rather than on the head, so `head_pipeline.sha` legitimately differs from the merge request's `sha` (GitLab: [merged results pipelines](https://docs.gitlab.com/ci/pipelines/merged_results_pipelines/), [merge trains](https://docs.gitlab.com/ci/pipelines/merge_trains/); both are Premium and Ultimate features and do not exist on GitLab CE or Free).
`bin/fm-pr-merge.sh` accepts such a pipeline only as this merge request's own pipeline and only when it covers the current revisions:

- the pipeline's `ref` is exactly `refs/merge-requests/<iid>/merge` or `refs/merge-requests/<iid>/train` for the merge request's own iid, which is what identifies the pipeline as this merge request's own rather than another's;
- that ref's current tip in the project repository is exactly the commit the pipeline ran on, so a pipeline the ref has moved past is refused as superseded rather than merged;
- the tested commit has exactly two parents, with the live source head as its second parent, so both source advances and rewinds refuse stale results;
- a merged-results commit has the current target tip as its first parent; a train commit must have matching GitLab provenance proving an exact parent chain rooted at the current target tip.

The pipeline's kind and iid, and the merge request's head and target branch, come from the same live merge request view as every other pre-merge condition; the ref, the tested commit, and the target branch tip come from the merge request's own project repository.
The [target-branch merge-train endpoint](https://docs.gitlab.com/api/merge_trains/#list-all-merge-requests-in-a-merge-train) supplies all active cars across every page, ordered by car ID.
Each car through the requested merge request must have exactly two parents, with its first parent equal to the preceding car's tested commit, or the current target tip for the first car.
The requested car must report the same successful pipeline ID, SHA, and ref.
Cars must report `fresh`, but that status alone does not prove target freshness.
Missing, unreadable, stale, or mismatched train provenance refuses acceptance.

The fixture's merged result shows the shape those refs carry on a live instance:

```
$ git ls-remote https://gitlab.com/KarotKris/gitlab-merge-watch-fixture.git "refs/merge-requests/2/merge"
4ee1baff65593d0091283b40533c3d87c8200584	refs/merge-requests/2/merge
$ git log --format="%H %P" -1 refs/merge-requests/2/merge
4ee1baff65593d0091283b40533c3d87c8200584 03a7d33b229e80ced8af9b9534ed2affc4972cd3 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

That merged result's first parent is the target branch tip and its second parent is the merge request's head, in the order the guard requires.
No licensed instance was available to run a real merged-results or merge-train pipeline, so no live pipeline of either kind is claimed here; `tests/fm-pr-merge.test.sh` exercises the accepted proofs and every refusal hermetically, building the same refs and topologies, including a chained car whose target is an ancestor rather than a parent, and asserting that a merge runs only on proven provenance and is always bound to the live head with `--sha`.

A pipeline that did not run at the head and cannot be proven this way refuses the merge, and the refusal names the fact that could not be proven.

## Why the head is read live and bound to the merge

After acquiring the away-record lock, the guard repeats the live mergeability checks and full pipeline proof immediately before merging.
It refuses any observed change in the source head, target branch or tip, pipeline identity or ref, or train provenance.
The verified head is passed to `glab mr merge --sha`, so GitLab refuses the merge if the source branch moved between the read and the merge.
Without it, a push landing in that window would merge commits nothing verified.

`--yes` is passed for the same reason the watch poll needs no terminal: an unattended run cannot answer a confirmation prompt, and a wedged prompt is worse than a refusal.
It skips only that prompt; the conditions above are what authorize the merge.

## Why a recorded head is not the authority

`bin/fm-pr-check.sh` records `pr_head=` for both forges: `gh` exposes a GitHub pull request's head commit as a selectable field, and a GitLab merge request's own head ref supplies the same fact ([above](#the-merge-requests-own-head-ref)).
The record is optional by design; [architecture.md](architecture.md) owns review fallback and teardown behavior.

The merge path deliberately does not depend on a recorded head.
A rebase moves the head and leaves any recorded value stale, so a merge decided from metadata can verify a commit that no longer exists.
Reading the head live at merge time, reporting a recorded value that disagrees, and binding the merge to what was actually verified is what closes that gap.
