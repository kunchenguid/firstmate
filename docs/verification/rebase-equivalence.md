# Rebase-equivalence verification

Repeatable evidence that [`../../bin/fm-rebase-equivalence.sh`](../../bin/fm-rebase-equivalence.sh) refuses a rebase that drops validated content and clears one that does not.
The predicate, its verdict vocabulary, and why it is neither a tip-to-tip diff nor a merge-result comparison are owned by that script's header and `--help`; this page records evidence only.

Date: 2026-08-10.
Git: 2.53.0.
ShellCheck: 0.11.0 (the pin `bin/fm-lint.sh` enforces).

## Why this check exists

The `no-mistakes` pipeline rebases a branch onto its target immediately before pushing it.
Twice in one day that rebase produced a pushed head that had silently lost content the pipeline had already validated, and the opened PR misrepresented what was judged.
Neither loss was reported by any pipeline signal; both were caught only by comparing content by hand.

The push step itself is not reachable from this repository.
`no-mistakes` is a single compiled binary (`~/.no-mistakes/bin/no-mistakes`, 24 MB, v1.40.3 at the date above), and its configuration schema exposes agent selection, timeouts, per-step `auto_fix` counts (including `rebase`), intent extraction, and test-evidence storage - no custom step, pre-push hook, or validation plugin.
So this repository owns the comparison and the refusal, and the generated no-mistakes ship brief requires a worker to run it before reporting its PR.

## Where the candidate head comes from

The pushed head is built inside the pipeline's own repository, never in the worker's clone.
A gate worktree's `.git` is a pointer file reading `gitdir: ~/.no-mistakes/repos/<id>.git/worktrees/<run>`, and objects flow worker to gate, never back.
The worker's `origin` compounds it, because it fetches upstream and pushes to the fork:

```
$ git remote -v
origin  https://github.com/kunchenguid/firstmate.git (fetch)
origin  https://github.com/sbracewell64/firstmate.git (push)
```

A check that could only name a local commit would therefore report `CANNOT-OBSERVE` on every run, including clean ones, which is a gate that never runs.
The forge is the one place both sides reach, and it publishes the request head as an ordinary ref on the repository the request was opened against:

```
$ git ls-remote origin 'refs/pull/2069/head'
13b1a8702cc128aa484641da30b581ced2429806        refs/pull/2069/head
```

`--candidate-pr` fetches that ref into `refs/fm-rebase-equivalence/candidate/<n>` and compares it, the same mechanism [`../../bin/fm-review-diff.sh`](../../bin/fm-review-diff.sh) already uses to keep a review current with an open PR.
It tries `--candidate-remote` (default `origin`) first and then the request URL's own host, so a request opened on the fork rather than upstream still resolves without this check owning the venue question.
End to end against the live forge, from a scratch clone whose `origin` holds no request refs at all:

```
$ bin/fm-rebase-equivalence.sh --repo <scratch> \
    --validated-base ed376cf --validated-head d459e94 \
    --candidate-pr https://github.com/kunchenguid/firstmate/pull/2069
REBASE-EQUIVALENCE: DROPPED 11 path(s) lost validated content
  ...
  (exit 3)
$ git -C <scratch> rev-parse refs/fm-rebase-equivalence/candidate/2069
13b1a8702cc128aa484641da30b581ced2429806
```

A fetch that cannot be made is `CANNOT-OBSERVE`, so the check still cannot pass by not running.

## Reproduction 1: whole paths dropped

Branch `fm/fork-trunk-serial2-base-red`, pushed head `eabefe42` on `sbracewell64/firstmate`.
The validated head kept the teardown fix, its two regression tests, and the ordered containment correction; the pushed head kept only the wall-clock commit.

```
$ git show 7aa333a:bin/fm-teardown.sh | grep -c ledger
14
$ git show eabefe42:bin/fm-teardown.sh | grep -c ledger
0
```

```
$ bin/fm-rebase-equivalence.sh --repo . \
    --validated-base ed376cf --validated-head 7aa333a --candidate-head eabefe42
REBASE-EQUIVALENCE: DROPPED 4 path(s) lost validated content
  dropped-content      bin/fm-teardown.sh: 39 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-remote-backlog-handoff.test.sh: 16 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-teardown.test.sh: 50 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-test-lib-wait.test.sh: 3 line(s) added by the validated change are absent from the candidate
  (exit 3)
```

Adding `--candidate-base origin/main`, which resolves this candidate's own base to `74230fc`, reports the same four paths.
An earlier revision of this check also named `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` as resurrected content; measuring the candidate against its own base shows that line came from the trunk, so it was a false positive rather than a fifth loss.

## Reproduction 2: hunks dropped inside surviving paths

Upstream `kunchenguid/firstmate` PR 2010, head `352c5691`, base `main` at `74230fc`.
The rebase dropped the pipeline's own accepted review-fix hunks.
Path footprints alone do not detect this: the two contributions touch nearly the same file set, so only a content-level comparison sees it.

```
$ bin/fm-rebase-equivalence.sh --repo . \
    --validated-base ed376cf --validated-head d459e94 --candidate-head 352c5691
REBASE-EQUIVALENCE: DROPPED 4 path(s) lost validated content
  dropped-content      AGENTS.md: 1 line(s) added by the validated change are absent from the candidate
  dropped-content      bin/fm-attempt.sh: 7 line(s) added by the validated change are absent from the candidate
  dropped-content      bin/fm-teardown.sh: 10 line(s) added by the validated change are absent from the candidate
  dropped-content      docs/architecture.md: 1 line(s) added by the validated change are absent from the candidate
  (exit 3)
```

`bin/fm-attempt.sh`, `bin/fm-teardown.sh`, and `docs/architecture.md` are exactly the three the by-hand comparison found.

## Discrimination: the same validated head, rebased faithfully, passes

A refusal is only evidence if the check also clears a correct rebase.
Validated head `d459e94` was rebased onto a later trunk commit in a scratch clone with no conflicts, producing `6326669`:

```
$ git rebase --onto ab6f98f ed376cf   # in a scratch clone, at d459e94
Successfully rebased and updated detached HEAD.
$ bin/fm-rebase-equivalence.sh --repo <scratch> \
    --validated-base ed376cf --validated-head d459e94 --candidate-head 6326669
REBASE-EQUIVALENCE: PASS validated content is carried by the candidate
  (exit 0)
```

Adding `--candidate-base ab6f98f` reports the same `PASS`.
Adding a further commit on top of that rebase, standing in for a pipeline fix made after validation, still passes (exit 0): the check refuses loss, never growth.
That property is what lets a worker compare its local validated head against a pushed head the pipeline legitimately moved on from.

## What `--candidate-base` adds

Removals are the one place two heads alone cannot settle the question.
A line the trunk added independently is indistinguishable from a validated removal the rebase undid when only the two heads are counted, and boilerplate makes that collision ordinary: a bare `fi`, `done`, or closing brace occurs many times in one shell file.
Reproduction 1's fifth path above is exactly that mistake, made by an earlier revision of this check.

Measuring the candidate against its own base separates the two, so the generated brief passes the trunk as `--candidate-base` and the check derives the candidate's own base from it with `git merge-base`.
Naming the trunk branch is therefore enough, even after it has moved past the commit the candidate was rebased onto.
Without it the check still refuses a line the validated change removed from a path entirely, which is the shape both reproductions took, and stays silent about counts it cannot attribute to the rebase rather than to the trunk.

Additions are deliberately not measured this way.
Content the candidate inherited from its trunk instead of re-applying is still content that landed, so the additions comparison stays absolute and asks only that the candidate hold at least as many copies of each line as the validated change net added.
Counting rather than looking up is what closes the hole where a hunk duplicating a line already in the file is satisfied by the copy that was already there.

## Why the merge result is not the predicate

Screening a landing with `git merge-tree --write-tree <trunk> <head>` is the right tool for asking what a branch does to a trunk, and its exit status is authoritative there.
It cannot serve as the rebase-equivalence predicate, because the validated head is by construction still on its pre-rebase base.
Measured against reproduction 1:

```
$ git merge-tree --write-tree 74230fc 7aa333a   # trunk vs the VALIDATED head
f9787a72d13fef19cf58d33c571c3732da176eee
... CONFLICT (content) in 90+ files ...
  (exit 1)
$ git merge-tree --write-tree 74230fc eabefe42  # trunk vs the REBASED head
9787ec5d795a6339bd8b996db3d9cdfcc65c23e1
  (exit 0)
```

The two results are not comparable, so a merge-result equality check would refuse every rebase it was meant to screen.
Diffing each head against its own base measures only what that head contributes, which is the quantity a rebase must carry over.

## Regression coverage

`tests/fm-rebase-equivalence.test.sh` (28 assertions) builds every fixture commit by commit rather than running `git rebase`, so a scenario means exactly one thing.

Refusals: a whole path present at the validated head and absent from the candidate; hunks lost inside a surviving path; a dropped hunk whose lines all already occur in the file; a validated line removal undone, both with and without a candidate base; a validated file deletion resurrected; a binary path the candidate lacks entirely.
Each asserts the exit status, the `DROPPED` verdict, the direction, and the naming of the losing path.

Clearances: a faithful rebase whose validated lines all shifted position because the trunk edited around them; a hunk the trunk landed independently so the rebase had nothing left to apply; a line the trunk added that matches one the validated change deleted; a path whose tracked name globs onto its siblings; content added after validation; whitespace-only churn.

The forge cases keep each candidate only under a request head ref in a bare fixture repository, cloned with `--no-local` so the worker cannot hold those objects for free.
Any verdict other than could-not-observe there is itself proof the fetch ran: a dropping candidate is refused, a faithful one passes, and a request URL resolves to the same head as its number.

Could-not-observe, each of which a check that treated an unusable input as "nothing to do" would report as a pass: an unresolvable ref, a missing directory, a directory that is not a git repository, a missing required argument, an empty validated contribution, a binary path that changed, a request head that cannot be fetched, an unparseable request, two candidates named at once, and an unresolvable candidate base.
A binary path whose blob is identical is still a sound observation and passes.
A final case asserts every outcome prints a verdict line and exits with that verdict's own status, so a caller can tell "compared and passed" from "never ran".

`tests/fm-brief.test.sh` pins the gate in the generated no-mistakes brief: the script's path, the pass verdict as the only clearance, the `--candidate-pr` form, both `blocked:` reports, and the absence of any instruction to name a pushed head the worker's clone cannot hold.
