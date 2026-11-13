# External review forge (forge=external)

Some projects review code through a tool that uploads its own snapshot of the author's local commits, with no git push and no pull request.
On such a project a worker never needs to push a branch, and must never push a task branch to the project's shared origin, where colleagues would see firstmate's delivery branches.
This document is the design for that rail; `bin/fm-project-mode.sh`'s header owns the registry binding, `bin/fm-dod-lib.sh` owns what it changes for a worker, and [configuration.md](configuration.md#external-review-tool-configexternal-reviewmd-configexternal-review-url-configexternal-review-backup) owns the home configuration schema.

## Why it is a forge value

[gerrit-forge-integration.md](gerrit-forge-integration.md) section 3 defines the forge as what the publication artifact is, and therefore which tool makes it.
Here the artifact is a review that an external tool creates from a snapshot of local commits, so the rail is a fourth value of the existing closed `forge=` binding rather than a separate axis.
The composition test holds: `local-only` is refused because it publishes nothing, `direct-PR` validates and then uploads with the tool, and `no-mistakes` is refused for now because the pipeline's push, pr, and ci steps would push to the shared origin.
The binding is never detected, because no protocol fact identifies a snapshot-uploading review tool; the captain's registry entry `[direct-PR forge=external]` is the whole binding.
The tool itself is private home configuration: `config/external-review.md` holds the worker instructions for validating, uploading, reading review state, and the stopping point, and `bin/fm-dod-lib.sh` renders it verbatim into the Definition of done.

## The no-push invariant

The invariant is enforced in three layers, from strongest to weakest:

1. A per-task `pre-push` guard, `bin/fm-git-push-guard.sh`, runs from the read-only hooks directory `bin/fm-spawn.sh` installs through `bin/fm-git-strip-ai-trailers.sh install --push-guard`, even when the home keeps AI trailers.
   It refuses any push to `origin` or to a URL matching one of origin's URLs, any push of the task branch or a task-prefixed ref to any remote, and any ref outside the backup prefix on the backup remote, then chains to the repository's own `pre-push` hook.
2. `bin/fm-spawn.sh` refuses `--yolo on`, a missing review tool adapter, and an unusable backup remote before any endpoint exists, and records `forge=external`, `backup_remote=`, and `backup_prefix=` in the task metadata.
3. The generated brief's first rule forbids every such push, and its Definition of done names the review tool as the only publishing path.

The ready report is `done: review <url> uploaded for review`.
Firstmate cannot observe, approve, or merge the review, so `bin/fm-review-check.sh` records `review=` and `review_head=` without arming a merge watch, and the review always escalates to the captain whatever the yolo setting.
A scout launches without the guard and the task record, so `bin/fm-promote.sh` refuses to promote one onto a `forge=external` project; such work starts as a ship.

## The personal backup remote

A worker copy's commits live only in the copy and in the review tool's snapshot.
`config/external-review-backup` may name a git remote, pointing at storage the captain alone controls, that holds a durable copy at `refs/heads/<backup-prefix><task-id>` (default prefix `backup/`).
The backup prefix must be non-empty and must neither equal nor start with the task branch prefix, so a durable copy never reads as a delivery branch and the guard's task-prefix rule stays unconditional.
Spawn refuses a backup remote the project does not have, or one whose URL matches origin's.
Where the backup remote points is the captain's call; firstmate cannot police it, so a project whose code must not leave a network needs a backup inside that network.

With a backup configured, the ready report is accepted only once HEAD is on the backup remote's namespace, and teardown's existing landed-work test sees the copy as reachable from a remote-tracking ref.
Without one, the ready report is accepted on the review URL alone, because the snapshot lives in a tool firstmate cannot read; `review_head=` records what was uploaded.
Teardown is unchanged either way, so without a backup it refuses cleanup until the reviewed content reaches origin's default branch, and the worker copy is retained until a human merges the review.

## Accepted residual

`git push --no-verify` skips every hook, a tool that writes refs without running git never reaches one, and an alias URL spelled differently from origin, such as an ssh form against an https form of the same server, does not compare equal.
Each bypasses the guard, and the brief's first rule still forbids all three.
No gate or cleanup step requires a push on this forge, which removes the pressure that would make a worker try one.

## Deferred

`no-mistakes` composition, which would run the pipeline with its forge-facing steps skipped and recover custody as Gerrit does, an adapter hook that verifies the uploaded snapshot against HEAD, per-project adapters, and promotion of a scout onto this forge are follow-ups.
