# Forge merge-watch and merge verification

Empirical record for the merge watch and merge path across firstmate's three supported forges: GitHub, GitLab, and Gitea/Forgejo.
GitHub is the fixed-host baseline; the GitLab evidence below was gathered on 2026-07-21 and the Gitea/Forgejo evidence on 2026-07-31, and each command's output is reproduced exactly as run.

## Why the host is data rather than a constant, for GitLab and Gitea/Forgejo

GitLab and Gitea/Forgejo both run mostly on self-hosted instances, so a merge request or pull request on either can live under any host.
A GitLab project also sits under at least one group at no fixed depth, so no owner-and-repository pair can address one the way it can on GitHub; Gitea/Forgejo, by contrast, keeps GitHub's fixed owner/repository shape even though its host is arbitrary like GitLab's.
The stored record therefore carries `provider`, `url`, `host`, `path`, and `number` for every provider, and every consumer rebuilds the URL from those parts and refuses any record that does not reconstruct the stored URL exactly.
`tests/fm-pr-check-security.test.sh` asserts that neither `bin/fm-pr-lib.sh` nor `bin/fm-pr-poll.sh` contains the string `gitlab.com` at all, and the same holds for `gitea` against `github.com`/`gitlab.com`.

## GitLab

### Versions

```
$ glab --version
Current glab version: 1.53.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

### The evidence project

All live evidence here reads <https://gitlab.com/KarotKris/gitlab-merge-watch-fixture>, a public project that exists only to be this evidence.
It holds one deliberately merged merge request and one deliberately open one, so both outcomes can be shown against real data.
Every command against it reads a public merge request and needs no credential, so a reader can rerun each one and see the same output.
Its README asks that the open merge request be left open.

A non-default host appears below only as the placeholder `gitlab.example`, which resolves nowhere.
That is deliberate: the host-agnostic property is a property of the stored record and the poll's URL reconstruction, so it is demonstrated by inspecting those rather than by reaching any private instance.

### How plain glab is invoked, and why

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

### End to end: arming and polling a real merge request

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

### A missing CLI produces no wake, never a false merge

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

### Upgrade path from an existing armed watch

The stored record gained the provider tag, so its version moved to `fm-pr-poll-registration-v2` and a record written by the previous release no longer parses.
The existing non-executing migration handles that: it never runs the old artifact, and rebuilds the poll from the task's recorded pull request URL.
Starting from a poll armed exactly as the previous release wrote it:

```
$ head -1 state/t1.pr-poll-registration
fm-pr-poll-registration-v1
$ fm-pr-check-migrate.sh --checks-safe
PR_CHECK_MIGRATION: canonical polls rebuilt and armed; resume supervision for this home
$ head -2 state/t1.pr-poll-registration
fm-pr-poll-registration-v2
t1
$ cat state/.pr-check-migration.log
task t1: migration outcome tracking started before legacy poll handling
task t1: canonical legacy poll rebuilt and armed
```

The rebuilt poll works, verified against a pull request that is genuinely merged:

```
$ fm-pr-poll.sh --validated $(tr '\n' ' ' < state/t1.pr-poll)
merged
```

No armed watch is lost by upgrading.

### Merging a merge request

`bin/fm-pr-merge.sh` merges a GitLab merge request through the same recording and the same guards a GitHub pull request gets, addressed by the project URL rebuilt from the parsed host and path rather than a hardcoded owner/repository pair.
Merging needs `glab` for the read and `jq` to parse it, and either one absent refuses before anything is recorded, naming the missing tool.
`jq` is not one of firstmate's common tools, which is why the watch poll reads glab's field output instead: the merge path cannot do the same because `detailed_merge_status`, `has_conflicts`, `blocking_discussions_resolved`, and the head pipeline appear only in glab's JSON.
The poll's silence on a missing tool is safe because silence means "not merged yet"; a merge cannot be silent about it, so the requirement is reported rather than assumed.

The merge is refused unless every pre-merge condition holds, each read live at merge time rather than taken from recorded metadata: the merge request is open, `detailed_merge_status` is mergeable, `has_conflicts` is false, `blocking_discussions_resolved` is true, and the head pipeline succeeded at the exact current head commit.
Every failing condition is reported, not just the first, and a refusal still leaves `pr=` recorded and the merge poll armed, exactly as a failing `gh-axi pr merge` does on the GitHub side.
A project that runs no pipeline at all cannot merge through this path: a successful pipeline at the head is a condition, and "there is no pipeline" does not satisfy it.

A GitLab task records no `pr_head=` on its own (plain `glab` exposes the head commit only inside its JSON output, which the watch poll does not parse), but a recorded value that disagrees with the live head is reported rather than trusted, because a rebase moves the head and leaves the recorded value stale.
The verified head is passed to `glab mr merge --sha`, so GitLab itself refuses the merge if the source branch moved between the read and the merge; `--yes` skips only the interactive confirmation that no supervised run can answer, and the conditions above are what authorize the merge.

The remaining refusal conditions, and the merge itself, are covered by `tests/fm-pr-merge.test.sh` against fixtures.
The conflict, unresolved-discussion, and running-pipeline conditions were additionally exercised against real merge requests on a private instance; those runs cannot be reproduced here, so their identifiers stay out of this record.
The merge itself is not exercised against any live merge request, in either direction: `glab mr merge` has no dry run, so a live success path would mean merging someone's work to produce evidence.

## Gitea/Forgejo

Forgejo is a protocol-compatible fork of Gitea: same REST API shape, same `tea` CLI.
One provider implementation, tagged `gitea`, covers both.
Gitea/Forgejo has the same merge parity with GitHub that GitLab has above: `bin/fm-pr-merge.sh` merges a Gitea/Forgejo pull request the same way it merges a GitHub one, because a Gitea/Forgejo path is a fixed owner/repository pair, exactly like GitHub's, though without GitLab's live pre-merge condition read since tea exposes no equivalent fields.

### Why tea rather than fj

Forgejo ships its own `fj` CLI, but the captain found `tea` more reliable than `fj` in manual testing against their own self-hosted Forgejo instance, so firstmate uses `tea` for both Gitea and Forgejo rather than branching on which of the two a given instance runs.
In the environment this support was built and verified in, `fj` was not even installed, corroborating that call.

### Versions

```
$ tea --version
Version: 0.14.1	golang: 1.26.3	go-sdk: v0.25.1

$ bash --version | head -1
GNU bash, version 5.3.15(1)-release (x86_64-pc-linux-gnu)
```

### The evidence instance

Unlike GitLab's public throwaway fixture project, there is no public Forgejo fixture to point a reader at.
This evidence was instead gathered read-only against a real self-hosted Forgejo instance, using the `tea` login already configured and authenticated there (the moral equivalent of `gh`'s or `glab`'s own auth state); the host, owner, and repository names below are anonymized as `forge.example`/`owner/repo` the same way the GitLab section anonymizes its self-hosted-host demonstration as `gitlab.example`, since the property being demonstrated belongs to the command shapes and output fields, not to that specific instance.
Every command actually run only listed or read existing pull requests; none of it created, merged, or otherwise mutated anything.
A live end-to-end arm-and-merge cycle through `fm-pr-check.sh`/`fm-pr-poll.sh`/`fm-pr-merge.sh` was separately exercised against a real pull request on that same self-hosted Forgejo instance: the captain opened a small, real documentation-fix pull request from a short-lived feature branch into `main`, then ran this support's own check, poll, and merge scripts against it from an isolated scratch state directory so no real task state was touched.
The URL parsed correctly (provider `gitea`, host, owner/repository, and pull request number), the poll stayed silent the whole time the pull request remained open, `fm-pr-merge.sh` performed a real squash merge via `tea` that advanced the target branch by exactly one commit matching the pull request title, and the poll then printed exactly `merged` once the merge landed.
The cycle passed on the first attempt with no code changes required.

### The PR URL shape, confirmed from the live instance

```
$ tea pulls list --repo owner/repo --login forge.example --state all -f index,url -o csv
index,url
4,https://forge.example/owner/repo/pulls/4
3,https://forge.example/owner/repo/pulls/3
```

The path is "pulls" (plural), which is what distinguishes this shape from GitHub's singular "pull" and GitLab's "-/merge_requests" segment.

### tea has no per-index field selector, so state is read by listing

`tea pulls <index>` prints a fixed human-readable detail view and ignores `-f`/`-o` entirely; those flags only apply to `tea pulls list`.
So, unlike `gh pr view <n> --json state` or `glab mr view <n>`, there is no way to ask tea for one pull request's state directly.
The poll instead lists closed pull requests and matches the recorded index:

```
$ tea pulls list --repo owner/repo --login forge.example --state closed -f index,state -o csv
index,state
4,merged
3,merged
2,closed
1,merged
```

`state` already distinguishes `merged` from `closed`-but-not-merged as a derived display value, and `--state closed` returns both, so no open pull request can ever be misread as merged and no merged one is missed by the state filter.
Only an exact `merged` on the recorded index wakes firstmate, exactly as for GitHub's `MERGED` and GitLab's `merged`.
The list is read a page at a time via `--page`/`--limit=1000`, walking further pages until the recorded index turns up or a page with zero data rows marks the end of the list, so a merge does not go unnoticed once more than 1000 newer pull requests have closed since, however many pages that takes. A page's end is judged by data rows rather than raw output, since tea's CSV always includes the header line even on an empty page, and by rows actually returned rather than the requested `--limit`, since a server can clamp its own page size below 1000.

### tea's login-fallback notice stays off stdout

```
$ tea pulls list --repo owner/repo --state all -f index,state -o csv 2>/tmp/stderr; cat /tmp/stderr
index,state
...
NOTE: no gitea login detected, falling back to login 'forge.example' in non-interactive mode.
```

The notice goes to stderr, never stdout, so it never corrupts the parsed CSV; passing an explicit `--login` (as firstmate always does) suppresses it entirely.

### Login selection: matching a host to a configured tea login

Unlike `gh` and `glab`, `tea` addresses a self-hosted instance through a configured login rather than through the URL, so the poll and the merge path both resolve the login whose own endpoint matches the validated record's endpoint:

```
$ tea login list -o csv
Name,URL,SSHHost,User,Default
forge.example,https://forge.example,forge.example,someuser,false
```

The `URL` column, not the `Name` column, is the login's actual host; a login's name is an arbitrary local alias and is never assumed to equal its host.
Any ambiguity (more than one login matching the record's host) or absence (no login matching it) is refused silently by the poll, exactly like GitLab's missing-`glab` case, and is a reported blocker at merge time, exactly like GitLab's missing-`glab` case at arm time.
A validated PR URL never carries a port (the host class in the URL pattern excludes `:`), so it only ever names the default-port endpoint.
The comparison strips a scheme's default port (https `:443`, http `:80`) from each side, so a login configured with its default port matches the portless record that names the same endpoint.
Any other port is kept, so a login for a non-default port is never mistaken for the default-port endpoint the validated URL names.
The scheme itself stays part of the comparison: a validated PR URL is always `https` (the URL pattern requires the literal `https://` prefix), so a login configured on `http`, even for the identical host, names a different endpoint and never matches.

### No pr_head is available

`tea pulls list`'s `head` field is the source branch name, not a commit SHA, in every output format including `-o json`, and no other field exposes one:

```
$ tea pulls list --repo owner/repo --login forge.example --state all -f index,head,base-commit -o csv
index,head,base-commit
4,some-feature-branch,de4184303ff1767aad579ef02afd228f0193fc21
```

So, like a GitLab task, a Gitea/Forgejo task records no `pr_head=`; the same provider-agnostic teardown and diff fallbacks already cover its absence.

### Merging

`tea pulls merge <index> --repo <owner>/<repo> --login <name> --style <merge|rebase|squash|rebase-merge>` performs the merge; firstmate defaults to `--style squash` when the caller passes no explicit `--style`/`-s`, mirroring the GitHub path's default `--squash`.
This call was exercised live (see "The evidence instance" above), and is additionally covered by the hermetic fake-`tea` tests in `tests/fm-pr-merge.test.sh`.
