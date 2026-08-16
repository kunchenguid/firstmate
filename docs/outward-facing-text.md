# Outward-facing text

Outward-facing text is text a destination keeps and shows to whoever can read that destination: a PR title, a PR description, a commit message, and tracked repository content.
Publication is not retractable.
Closing a PR leaves its description readable, so text that reaches a public repository is public from then on whether or not anyone meant it to be.

Firstmate composes some of that text from a worker's working context.
Under the `no-mistakes` delivery mode, the run intent becomes the PR description verbatim, and that intent is derived from the brief's `# Task` section.
A worker's context also holds the machine it runs on, the fleet it belongs to, and every other repository that fleet touches, none of which the destination repository can resolve.

## The contract

**An identifier may appear in outward-facing text only when a reader holding the repository under change, and nothing else, could resolve it.**

This is a scoping rule and never a length rule.
The accepted requirements are exactly what a PR description is for, and shortening the intent is not a way to satisfy this contract.
The problem is foreign identifiers, not volume.

Legitimate: the accepted requirements and their rationale, behavior and interfaces, paths relative to the repository root, symbols, this change's own branch, issues and PRs in this repository, and commit ids that resolve in this repository.

Not legitimate: commit ids, branches, or issue references belonging to another repository; a firstmate task id, brief path, worker name, or other fleet-private name other than the one this change's branch already publishes; and absolute paths naming a user home, a per-run temporary root, or a gate or worktree clone on one machine.

An identifier a reader really can resolve, such as an upstream vendor's release id or a named upstream project's commit in a verification record, is legitimate once it is recorded in the repository's tracked `.fm-outward-allow` file.
Adding that line is the reviewable act that justifies the reference, in the same change that introduces it.

That file settles reviewable findings only.
A machine-local path, a private task id, or another project's name is blocking and can never be settled there, because recording one would publish in a tracked file the exact identifier this contract exists to keep unpublished.
The check reports such an entry alongside the finding rather than honoring it, and `--allow` is bounded the same way.

## The check

`bin/fm-outward-text-check.sh` decides every category against the repository under change rather than by keyword heuristics, so ordinary prose about dates, versions, commands, and relative paths is never matched.
Its header and `--help` own the exact options, categories, and known bounds.

```sh
bin/fm-outward-text-check.sh --home <firstmate-home> --task <task-id> intent.txt   # before publishing
bin/fm-outward-text-check.sh --diff --block-only                                   # prose and commit messages this branch adds
```

Findings carry a severity that reflects what an unattended gate can safely act on alone, not how bad a leak is.
A machine-local path or a private fleet identifier is blocking, because nothing outside that machine or that fleet can ever resolve it.
An unresolvable commit id or a URL naming another repository is reviewable, because the surrounding text can name an upstream that makes it resolvable and no check can confirm that.

Two places run it:

- Every generated `no-mistakes` and `direct-PR` brief requires the worker to check the intent or the PR body before publishing, where every finding must be cleared or justified.
  This is the only point that can act before a PR description exists, since a description cannot be recalled once posted.
  It is also the only point that runs against a firstmate home, so a foreign task id or another project's name is caught here and nowhere else.
- The `Repo invariants` CI job scans the prose and the commit messages this branch adds, and fails on blocking findings while listing reviewable ones.
  It runs without a firstmate home, so a machine-local path is the only blocking category that can fail it.
  It needs full history, because deciding whether an id resolves in this repository is impossible against a shallow clone.

Tracked prose has a second, separate owner: [`documentation-audiences.md`](documentation-audiences.md) routes task chronology, temporary paths, and one-off process identifiers to private task reports.
That policy is about where knowledge belongs, and this check is about what a reader can resolve.
The audience check deliberately does not lint prose, and this one deliberately resolves identifiers instead of matching words.
