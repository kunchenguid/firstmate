# Gerrit change watch verification

Empirical record for the merge watch on Gerrit, alongside the existing GitHub and GitLab ones.
It covers what the watch reads, why it reads that field and not a neighbouring one, and why the merge path refuses.
Every output below is reproduced verbatim except for the server host, project name, and change numbers, which are replaced throughout by the placeholders the test fixtures use.

## Versions

```
$ gerrit-axi --version
gerrit-axi 0.2.0

$ jq --version
jq-1.7

$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

## The evidence changes

The live evidence here reads two changes on a private Gerrit server, so a reader outside that network cannot rerun these commands against the same data.
The server is named below as `review.internal` and its project as `group/apps/console`, the placeholders the fixtures use; every other byte is the tool's own output.
What these transcripts establish is a property of Gerrit's own record shape rather than of any one server, and the hermetic regression in `tests/fm-pr-check-security.test.sh` pins every one of them with no server at all, so the reproducible check is that suite rather than these transcripts.
Change 4200 is merged, and change 4201 was open and blocked on review when this was collected.

## Status is read explicitly, because submittability is a different question

This is the fact the whole adapter turns on, collected 2026-09-23.

```
$ gerrit-axi show 4200 --host review.internal --json
      "change": 4200,
      "status": "MERGED",
      "submit": "OK",
      "submittable": true,
      "blocked_on": "",

$ gerrit-axi show 4201 --host review.internal --json
      "change": 4201,
      "status": "NEW",
      "submit": "NOT_READY",
      "submittable": false,
      "blocked_on": "Code-Review",
```

A merged change still reports `submit: OK`, `submittable: true`, and an empty `blocked_on`.
An open change that has collected its approvals reports exactly the same three fields, because that is what "ready to submit" means.
So `submit`, `submittable`, and `blocked_on` answer "could this be submitted", and only `status` answers "was it".
A watch built on any of the first three reports a merge for an approved change nobody has submitted.

`blocked_on` is still the right field for readiness, and vote values are not: Gerrit decides what blocks submission from its own submit requirements, which a caller cannot reconstruct by adding up label values.
Nothing in this adapter reads readiness, but the distinction is recorded here because the next thing built on this record will want it.
A new patch set drops both blocking votes, and a rebase is a new patch set, so a readiness reading is only ever true of the patch set it was taken from.

## The change number is the whole match, and the server's own URL is not

`gerrit-axi` reports a change's `url` straight from `gerrit query` (`src/core/changes.js`, `url: row?.url ?? null`), and Gerrit composes that field from `gerrit.canonicalWebUrl`, omitting it when the setting is unset.
So the field is null on a server that has never been told its own web address, and it names the canonical host rather than the alias a reader may have pasted the change URL from.
Comparing it against the stored URL would therefore arm a watch that can never wake: the poll is silent on every failure, so a change on such a server would be polled forever and its merge never reported, with nothing distinguishing that from a change nobody has submitted.

A change number is server-global on Gerrit and `--host` already pins the server, so the number alone names the change.
The watch matches on the number and reads nothing else for identity; the recorded project path addresses the change for a human reader and is not part of the read.

## The host must be passed explicitly

The poll runs from the firstmate home, in no repository.
Collected 2026-09-23:

```
$ cd /tmp && gerrit-axi show 4200 --json
{
  "ok": false,
  "op": "show",
  "error": "cannot determine the Gerrit host",
  "code": "HOST_UNRESOLVED",
  "kind": "config",
```

`gerrit-axi` resolves its server from the current directory's `origin` remote first, so outside a clone it has nothing to reach.
The poll is silent on every failure, so without `--host` the watch would wait forever on a change it never looked at.
`bin/fm-pr-poll.sh` therefore passes `--host` from the validated record, and `bin/fm-crew-state.sh` reads an open change's status through the same explicit host.
`--host` pins only the server, and the SSH user and port resolve down that same current-directory `origin` path before falling back to the local login name and 29418, so watching a change requires `GERRIT_USER` - and `GERRIT_PORT` on a server that does not use 29418 - set in the watcher's environment or in `~/.config/gerrit-axi/config.json`, because the poll cannot report that it never authenticated.

## The poll against the real server

Run from `/tmp`, outside any clone, against the published poll program, collected 2026-09-23.

```
$ bash bin/fm-pr-poll.sh --validated gerrit https://review.internal/c/group/apps/console/+/4200 review.internal group/apps/console 4200
merged

$ bash bin/fm-pr-poll.sh --validated gerrit https://review.internal/c/group/apps/console/+/4201 review.internal group/apps/console 4201

$ bash bin/fm-pr-poll.sh --validated gerrit https://review.internal/c/group/apps/console/+/999999999 review.internal group/apps/console 999999999
```

The merged change emits one `merged` line.
The open change and a change that does not exist both emit nothing.

## The merge path refuses

```
$ bin/fm-pr-merge.sh task-a https://gerrit.example/c/proj/+/1
error: firstmate does not submit a Gerrit change: submitting requires an attributed human approval it must not manufacture, so a human submits the change on the server
$ echo $?
2
```

The refusal runs before any metadata read, forge read, or recorded state.
Submitting a change means first recording a Code-Review+2, which is a positive attributed claim that a named human approved it, read by colleagues and by any audit of the repository.
The server permitting self-approval is what makes this a policy boundary rather than a capability limit, which is why it is enforced in the code rather than left to the absence of a provider branch.

## What the hermetic regression pins

`tests/fm-pr-check-security.test.sh` covers, with no server:

- The canonical change URL parses into the provider-tagged identity with its whole nested project path, and an adversarial URL matrix is refused.
- Only an exact `MERGED` status wakes the watch, and a fully submittable open change does not.
- A record naming another change never wakes the watch, and neither does a doctored sidecar.
- A merged record whose `url` is null, absent, or on an alias host still wakes the watch, because the change number is the whole match.
- A merged spelling inside a change's free-text subject cannot forge a status.
- An absent `gerrit-axi` or `jq` produces no wake, and arming reports the missing tool instead.
- Arming records no `pr_head`: a Gerrit revision names one patch set, and `bin/fm-review-diff.sh` has no Gerrit path to resolve a current head with, so a recorded revision would quietly become the reviewed content after the next amend.
- The merge path refuses a Gerrit change.
- Arming accepts a done naming a Gerrit change only when a live read shows the change's current patch set carrying the worker's HEAD tree, even when a remote-tracking ref such as the no-mistakes gate branch holds that HEAD, and refuses a mismatched, unknown, or unreadable patch set before recording anything.
- Once arming has recorded the change as `pr=`, a later done naming it is accepted from that record with no forge read, so a server-side rebase or new patch set does not revoke it.
- A no-mistakes done naming a Gerrit change is also refused unless the copy holds a passed pipeline's result: refused when the run's outcome is missing or not a pass, while the run reports `recover_custody` or `continue_active_run`, when HEAD's tree differs from the pipeline head's, or when the run cannot be read, and accepted once recovered even after the Change-Id stamp rewrote the branch's messages.
- A `published for review` done whose URL is not a canonical Gerrit change URL is refused, even when a remote-tracking ref holds HEAD.

`tests/fm-crew-state.test.sh` pins the crew-state read with no server either: a passed run whose change is open reports `PR open`, an abandoned one `PR closed`, a merged one `PR merged`, and an unreadable record or one naming another change reports an honest unknown rather than a merge.

Refresh this record by rerunning those suites, and rerun the transcripts above after a `gerrit-axi` upgrade.
