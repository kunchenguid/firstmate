# GitLab merge request watch and merge verification

Empirical record for the merge watch and the merge path on GitLab, alongside the existing GitHub ones.
The arming, poll, and missing-`glab` evidence through the GitHub-unaffected case was collected on 2026-07-21; "Merging a merge request" was run on 2026-08-22.
The head-recording evidence was collected on 2026-10-11, and the live end-to-end pass on 2026-10-13.
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

The 2026-10-13 end-to-end pass below was collected with:

```
$ glab --version
glab 1.122.0 (89d0008af)

$ jq --version
jq-1.6

$ git --version
git version 2.39.5

$ bash --version | head -1
GNU bash, version 5.2.15(1)-release (x86_64-pc-linux-gnu)
```

## The evidence project

All live evidence here except the 2026-10-13 end-to-end pass reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.
The 2026-10-13 pass merges a merge request for real, so it uses its own throwaway fixture, named in its section.

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
The poll keeps reading glab's own field output, because `jq` is not one of firstmate's common tools and the poll must stay silent-safe without it; merging, which refuses loudly rather than silently on a missing tool, requires `jq` and reads that JSON, and arming reads it only when `jq` is present (see the sections below).
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

Arming needs no other tool.
A missing `jq` does not refuse: the merge request's JSON, which the next section reads, is simply not read, so the watch arms as it does above with no draft check and no recorded `pr_head=`, exactly as the GitHub arm skips its own draft read without `jq`.
`tests/fm-pr-check-security.test.sh` pins that degradation against fixtures; it has no live run in this record.

## Arming records the merge request head (2026-10-11)

With `jq` on `PATH`, `bin/fm-pr-check.sh` reads one JSON view of the merge request at arming and uses it twice: a `work_in_progress` draft refuses exactly like the GitHub arm-time draft refusal, and `sha` is recorded as `pr_head=`.
Arming the merged fixture merge request records its head, matching the live head the 2026-08-22 merge refusal below verified:

```
$ fm-pr-check.sh e1 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
armed: state/e1.check.sh
$ grep -E '^(pr|pr_head)=' state/e1.meta
pr=https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/1
pr_head=33762fcf6777c8d993220d25fb541e56c48081b9
```

That arming refusal also ran live against a real draft merge request on 2026-10-13 (the "Live end to end" section at the end of this record), so both the unit pin and a real forge reading exist now.
An unreadable draft state still does not refuse, matching how the head read is optional.

## Registration version

The live registration tag is `fm-pr-poll-registration-v2`, which includes the provider tag.
A `fm-pr-poll-registration-v1` record no longer parses.
Arm a current watch with `bin/fm-pr-check.sh`.

## Merging a merge request

`bin/fm-pr-merge.sh` now merges a GitLab merge request through the shared recording helper and GitLab's own live pre-merge guards.
Every run in this section used a throwaway `FM_HOME`, so no live task record was touched, and a `glab` wrapper that refused any `merge` subcommand outright, so no merge could reach the forge even if a check were wrong.
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

By default, a project that runs no pipeline at all therefore cannot merge through this path.
That is the intended reading of the requirement rather than an oversight: a successful pipeline at the head is a condition, and "there is no pipeline" does not satisfy it.
The only exception is an attended `--allow-no-pipeline` on an explicit captain order, which waives exactly this null `head_pipeline` and nothing else; the header of `bin/fm-pr-merge.sh` owns its guards.

Both refusals came after `pr=` was recorded and the merge poll was armed, as a failed live verification or `gh pr merge` does on the GitHub side, so a refusal still leaves the audit trail and the watch in place.

A recorded `pr_head=` that no longer matches the live head is reported, and the live head is what gets verified.
The stale value below was written into the task record by hand, so it disagrees with what arming would have recorded:

```
$ fm-pr-merge.sh e4 https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
armed: state/e4.check.sh
notice: recorded head 1111111111111111111111111111111111111111 disagrees with the live head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8; verifying the live head
error: refusing to merge https://gitlab.com/KarotKris/gitlab-merge-watch-fixture/-/merge_requests/2
  - the head pipeline status is "none", not success
  - the head pipeline ran at "none", not at the current head 66b8a6777bea5e291d7fa2fc20c42ad7686f6bc8
```

The remaining refusal conditions, and the merge itself, are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The merge adds no merge-method flag when the caller names none, because the project's own merge method applies; the same test file pins that.
The conflict, unresolved-discussion, and running-pipeline conditions were additionally exercised against real merge requests on a private instance; those runs cannot be reproduced here, so their identifiers stay out of this record.
The merge itself is not exercised against this fixture, in either direction: `glab mr merge` has no dry run, so a live success path here would mean merging the merge request the fixture keeps open.
The one live merge in this record is the throwaway merge request of the 2026-10-13 pass below.

## Why the head is read live and bound to the merge

The verified head is passed to `glab mr merge --sha`, so GitLab refuses the merge if the source branch moved between the read and the merge.
Without it, a push landing in that window would merge commits nothing verified.

`--yes` is passed for the same reason the watch poll needs no terminal: an unattended run cannot answer a confirmation prompt, and a wedged prompt is worse than a refusal.
It skips only that prompt; the conditions above are what authorize the merge.

## Why a recorded head is not the authority

`bin/fm-pr-check.sh` records `pr_head=` for GitHub and GitLab alike: `gh` exposes the head commit as a selectable field, and the GitLab arm reads the merge request's JSON when `jq` is present (see above).
It is optional by design, and the other consumers treat it that way: `bin/fm-teardown.sh` proves a merge request landed through the merged state read plus a fetch of `refs/merge-requests/<iid>/head`, the ref GitLab keeps for every merge request including a merged one, and `bin/fm-review-diff.sh` fetches that same ref by default with a recorded `pr_head=` only as its offline fallback.
A Gerrit task records none, because a Gerrit revision names one patch set and every amend or rebase is a new one.

The merge path still does not depend on one, and deliberately so.
A rebase moves the head and leaves any recorded value stale, so a merge decided from metadata can verify a commit that no longer exists.
Reading the head live at merge time, reporting a recorded value that disagrees, and binding the merge to what was actually verified is what closes that gap.

## Live end to end: draft refusal, fresh review fetch, real squash merge, landed-work proof (2026-10-13)

The earlier sections proved each guard with refusals read live but never drove a merge request all the way through arm, draft refusal, review, merge, and teardown on a real instance.
This pass did, against a fresh public throwaway fixture, https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture, merge request https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1.
Every command below ran with the real `glab`, `git`, and `jq` on PATH; only the non-forge surroundings (tmux window close, worktree return, the no-mistakes run check) ran as no-op stubs, exactly the hermetic split the unit tests use, because the surface under evidence is the GitLab paths.
The fixture repo's one-job pipeline ran on a project-scoped runner created for it on this box after the personal namespace had no shared runner available; the runner was stopped and its registration deleted after the merge, and the repo carries only throwaway content.

A draft merge request refuses arming live, exactly as designed:

```
$ glab mr update 1 --draft -R gh0stwin/firstmate-gitlab-port-fixture
✓ marked as Draft
$ fm-pr-check.sh live-evidence https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1
error: https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1 is a draft merge request; a draft cannot be merged, so merge monitoring would wait for an event that cannot occur - mark it ready for review and arm again, or declare a wait instead of done if the draft is deliberate
$ echo $?
1
```

The task metadata was byte-identical after the refusal and no poll was armed.
Marked ready, the same arm records the head and arms:

```
$ glab mr update 1 --ready -R gh0stwin/firstmate-gitlab-port-fixture
$ fm-pr-check.sh live-evidence https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1
armed: state/live-evidence.check.sh
$ grep -E '^(pr|pr_head)=' state/live-evidence.meta
pr=https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1
pr_head=d93a01ff9e15a8c61eda208cad96ce1a24629e07
```

Advancing the source branch to `852919f4e3dd57a222f6ab3b4e825138eed149ed` then left that recorded head stale, and `bin/fm-review-diff.sh` still compared against the freshly fetched `refs/merge-requests/1/head` rather than the record:

```
$ fm-review-diff.sh live-evidence --stat
diff base: origin/main
 .gitlab-ci.yml | 2 ++
 NOTES.md       | 2 ++
 2 files changed, 4 insertions(+)
```

`NOTES.md` at the stale head would have shown one insertion; two proves the fresh ref won, the offline fallback never fired.
With the head pipeline at `852919f` green, the guarded merge verified every condition live, named the stale record, and squashed:

```
$ fm-pr-merge.sh live-evidence https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1
armed: state/live-evidence.check.sh
notice: recorded head d93a01ff9e15a8c61eda208cad96ce1a24629e07 disagrees with the live head 852919f4e3dd57a222f6ab3b4e825138eed149ed; verifying the live head
verified: https://gitlab.com/gh0stwin/firstmate-gitlab-port-fixture/-/merge_requests/1 is open and mergeable, with a successful pipeline at head 852919f4e3dd57a222f6ab3b4e825138eed149ed
✓ Pipeline succeeded.
✓ Merged!
```

This pass was collected while `bin/fm-pr-merge.sh` still added `--squash` to a merge whose caller named no method, so the merge above was sent as a squash; that default has since been removed and the script now adds no merge-method flag.
The landed-work proof below does not depend on the method: it reads the merged state and the containment of the local work in `refs/merge-requests/1/head`.

The merge request reports `state=merged` with merge commit `dccd89d`, and the teardown landed-work proof accepted it through the merged-state read plus the `refs/merge-requests/1/head` fetch, syncing the project clone and completing the task:

```
$ fm-teardown.sh live-evidence
/home/node/firstmate/data/track-firstmate-upstream-pr-7226/live/project: synced 55b08d0..dccd89d
teardown live-evidence complete (window firstmate:fm-live-evidence, worktree /home/node/firstmate/data/track-firstmate-upstream-pr-7226/live/wt)
$ echo $?
0
```
