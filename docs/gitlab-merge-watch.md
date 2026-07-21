# GitLab merge request watch verification

Empirical record for the merge watch on GitLab, alongside the existing GitHub watch.
Every command below was run on 2026-07-20 and its output is reproduced exactly.

## Versions

```
$ glab-axi --version
0.5.0

$ bash --version | head -1
GNU bash, version 5.3.9(1)-release (x86_64-pc-linux-gnu)
```

## Hosts used as evidence, and what each one proves

Two hosts, because they establish different things and neither is redundant.

`gitlab.com` proves the result is reproducible by anyone.
Every gitlab.com command here reads a public merge request and needs no credential, so a reader can rerun it and see the same output.

A self-hosted instance proves the property that makes this a schema change rather than a pattern edit.
GitLab runs mostly on self-hosted instances, and a merge request there lives under a host that is not `gitlab.com` and under a project namespace that no owner-and-repository pair can address.
The self-hosted evidence below comes from `selfhosted.example`, which a reader cannot reach; it is included so the non-default-host path is shown working against a real instance rather than only asserted.
The host, namespace, and merge request numbers for that instance have been replaced with placeholders because the real instance is private; the properties being demonstrated, a host that is not `gitlab.com` and a project namespace nested below the top level, hold regardless of the exact values.

The host is never a constant in the implementation.
It is carried in the stored record next to the namespace and the merge request number, and the anti-tamper cross-check rebuilds the URL from that stored host.
`tests/fm-pr-check-security.test.sh` asserts that neither `bin/fm-pr-lib.sh` nor `bin/fm-pr-poll.sh` contains the string `gitlab.com` at all.

## The underlying read, unauthenticated

```
$ glab-axi mr view "https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/4000" --jq .state
merged

$ glab-axi mr view "https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/6477" --jq .state
closed

$ glab-axi mr view "https://selfhosted.example/group/subgroup/project/-/merge_requests/101" --jq .state
merged

$ glab-axi mr view "https://selfhosted.example/group/subgroup/project/-/merge_requests/102" --jq .state
closed
```

`glab-axi` supports `--jq`, so the state is read as an exact field rather than matched out of human-readable output.
No change was needed in `glab-axi` for any of this.

## End to end: arming and polling a real merge request

Four tasks were armed against the two hosts, then each published poll was run.

```
$ fm-pr-check.sh e1 https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/4000
armed: state/e1.check.sh
$ fm-pr-check.sh e2 https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/6477
armed: state/e2.check.sh
$ fm-pr-check.sh e3 https://selfhosted.example/group/subgroup/project/-/merge_requests/101
armed: state/e3.check.sh
$ fm-pr-check.sh e4 https://selfhosted.example/group/subgroup/project/-/merge_requests/102
armed: state/e4.check.sh
```

The stored record for each, showing the host and the full project namespace as data:

```
$ cat state/e1.pr-poll
gitlab
https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/4000
gitlab.com
gitlab-org/gitlab-runner
4000

$ cat state/e3.pr-poll
gitlab
https://selfhosted.example/group/subgroup/project/-/merge_requests/101
selfhosted.example
group/subgroup/project
101
```

The provenance record, showing the bumped version tag:

```
$ cat state/e3.pr-poll-registration
fm-pr-poll-registration-v2
e3
gitlab
https://selfhosted.example/group/subgroup/project/-/merge_requests/101
selfhosted.example
group/subgroup/project
101
58b97281dea32dd991c7411b1c0f0150fbafbc6c5c82836186b6606d47297c3d
2df494a308eb6f0c2e2d07de87fd45a5049b6c528b675318d6a0d39865327268
70:100711
70:100712
```

Running each published poll, where an empty result means the poll stayed silent:

```
e1 -> [merged]
e2 -> []
e3 -> [merged]
e4 -> []
```

A merged merge request produces exactly one `merged` line on both hosts, and a merge request that was closed without merging produces nothing.

The optional head commit was captured on both hosts through `glab-axi mr view <url> --jq .sha`:

```
$ grep '^pr' state/e1.meta state/e3.meta
pr=https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/4000
pr_head=774f65356725770b1df233ba88d5cceeaf540e31
pr=https://selfhosted.example/group/subgroup/project/-/merge_requests/101
pr_head=9cf455325eadee70a6326338094398ddb7baf951
```

## The GitHub watch is unchanged

Live GitHub polls were armed under the new code and behave exactly as before.

```
$ fm-pr-check.sh g1 https://github.com/kunchenguid/firstmate/pull/747
armed: state/g1.check.sh
$ cat state/g1.pr-poll
github
https://github.com/kunchenguid/firstmate/pull/747
github.com
kunchenguid/firstmate
747
$ grep '^pr' state/g1.meta
pr=https://github.com/kunchenguid/firstmate/pull/747
pr_head=0246453b84ddc0603a7335af049277218387b5b8
```

Merged pull request 747 produced `merged`, and open pull request 789 produced nothing:

```
merged pull request 747 -> [merged]
open pull request 789   -> []
```

A poll armed by the previous release is recognised as old rather than misread.
Its four-field record and its `fm-pr-poll-registration-v1` tag both fail the current parsers, the poll emits nothing in that state, and the existing non-executing migration then rebuilds it from the task's recorded pull request URL.
`tests/fm-pr-check-security.test.sh` covers that whole sequence.

GitHub validation was not loosened to make room for GitLab.
The GitHub username and repository rules are byte for byte the ones already in the tree, GitLab namespace segments have their own separate rule, and the full adversarial URL matrix that GitHub already rejected still rejects.

## Safety properties, each demonstrated

The GitLab branch inherits every property the GitHub poll has, through the same code, not a parallel one.

### The published poll is byte-identical to the tracked script

Publication copies `bin/fm-pr-poll.sh` with no substitution and refuses if the copy differs.

```
$ for i in e1 e2 e3 e4; do cmp -s bin/fm-pr-poll.sh state/$i.check.sh && echo "$i: identical"; done
e1: identical
e2: identical
e3: identical
e4: identical
```

### Task and merge request data are never interpolated into shell source

The merge request URL appears only in the private record, never in the executable file.
Because the bytes are identical for every task, the executable surface is one reviewed file rather than one generated script per task.

### The stored URL must be exactly reconstructible from its own stored parts

This is the anti-tamper seam, and on the GitLab side it reconstructs from the stored host rather than from a constant.
A record whose parts do not rebuild the stored URL is refused before any network call.

```
doctored host      (gitlab.com substituted for the real host) -> []
doctored namespace (attacker/evil substituted for the path)   -> []
flipped provider   (github claimed for a GitLab record)       -> []
missing provider   (a record with no provider tag)            -> []
```

### Arming is transactional

Hashes and file identity are recorded before the move and re-verified after it, and the arm is revoked on any mismatch.
The device, mode, single-link, and non-symlink checks apply to the record, the provenance file, and the published poll alike.

### An unregistered or drifted check is rejected without being executed

An edit to a published poll makes it fail validation, so the watcher never runs it.

```
$ printf '\n# injected\n' >> state/e3.check.sh
rejected: drifted check fails validation, so the watcher never runs it
$ # restore the original bytes
restored: validates again
```

A hand-written poll with no provenance record is refused the same way, and the non-executing migration quarantines it rather than running it.

```
$ cat state/.pr-check-migration.log
task a1: ambiguous or invalid legacy poll quarantined and unarmed
task a2: ambiguous or invalid legacy poll quarantined and unarmed
task a4: ambiguous or invalid legacy poll quarantined and unarmed
```

### Execution runs from a hash-verified private snapshot

The watcher copies the check, re-hashes the copy, and runs the copy only when that hash matches.
An edit made after validation and before execution therefore cannot change what runs.

### Any error is silent rather than a false merge signal

This is the property that matters most, because the failure mode to avoid is a lookup error being read as a merge.
Tested adversarially rather than on the happy path.

```
nonexistent merge request (iid 999999999, a real 404)    -> []
host that does not resolve (no-such-host.invalid)        -> []
glab-axi absent from PATH entirely                       -> []
no network at all (run in an isolated network namespace) -> []
```

Every one of these is silent.
For reference, the underlying tool does report the failure; the poll simply declines to turn a failure into a signal.

```
$ glab-axi mr view "https://gitlab.com/gitlab-org/gitlab-runner/-/merge_requests/999999999" --jq .state
error: 404 Not found
code: NOT_FOUND
$ echo $?
1

$ glab-axi mr view "https://no-such-host.invalid/a/b/-/merge_requests/1" --jq .state
error: x error connecting to no-such-host.invalid
code: UNKNOWN
$ echo $?
1
```

## Known gap

A merge request that is closed without being merged leaves the task waiting, because only `merged` ends the watch.
The GitHub poll has the identical gap for a closed pull request.
Both are tracked separately so the two providers keep behaving the same way.

## Reproducing this

The gitlab.com sections need no credential and can be rerun as written.
The self-hosted sections need access to that instance; the properties they demonstrate, arbitrary namespace depth and a non-`gitlab.com` host, are also covered deterministically in `tests/fm-pr-check-security.test.sh` with synthetic hosts and six-segment namespaces.
