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

Only the repository the request URL names may answer for it.
A request number is unique within one repository, and every forge publishes the same head namespace for all of them, so the fork request 7 and the upstream request 7 are both `refs/pull/7/head` on their own hosts.
The remote configuration above is exactly that trap: `origin` fetches upstream, the pipeline opens the request on the fork, and upstream is past request 2071, so fetching `origin` for a fork request number succeeds and answers with somebody else's change.
A configured remote is therefore used only when its URL is proven to be the repository the request URL names, and refused rather than quietly substituted when it is not, because a confident verdict about code nobody asked about is worse than no verdict at all.
The regression suite constructs that collision rather than reasoning about it: the worker's own `origin` holds a request 7 that would clear the comparison, and the check reports `CANNOT-OBSERVE` instead of reading it.

The trunk comes from the request too, never from a local ref.
Whenever this check matters the trunk HAS moved, since otherwise no rebase would have been needed, so `refs/remotes/origin/<default>` is short of the commit the candidate actually sits on and would measure the removal comparison against the wrong base.
The base BRANCH is forge metadata rather than a ref, so `gh pr view <url> --json baseRefName` names it and its current tip is then fetched into `refs/fm-rebase-equivalence/base/<n>`; each head's own base is the `git merge-base` of that tip with that head, which is why the branch tip having moved on again does not matter.
With the trunk in hand the validated head's own base is the same fork point off the same trunk, so `--validated-base` is optional in this form and the worker's instruction is a single command naming only its own `HEAD` and the PR URL.

End to end against the live forge, from a scratch clone whose `origin` is a local path and holds no request refs at all:

```
$ bin/fm-rebase-equivalence.sh --repo <scratch> \
    --validated-base ed376cf --validated-head d459e94 \
    --candidate-pr https://github.com/kunchenguid/firstmate/pull/2069
REBASE-EQUIVALENCE: DROPPED 11 path(s) lost validated content
  ...
  (exit 3)
$ git -C <scratch> rev-parse refs/fm-rebase-equivalence/candidate/2069 refs/fm-rebase-equivalence/base/2069
13b1a8702cc128aa484641da30b581ced2429806
85e750ab9b76df275c1f6b9e2bc95b671955bae9
```

Dropping `--validated-base` from that command reports the same three-valued verdict with the base derived from the fetched trunk.
Every fetch runs with `GIT_TERMINAL_PROMPT=0` and non-interactive askpass and ssh settings, because an unattended worker blocked on a credential prompt prints no verdict line at all, and that is the one outcome a caller cannot tell apart from a crash.
A fetch that cannot be made, a base the forge will not name, and a remote that is not the request's repository are all `CANNOT-OBSERVE`, so the check still cannot pass by not running.

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
REBASE-EQUIVALENCE: DROPPED 5 path(s) lost validated content
  dropped-content      bin/fm-teardown.sh: 44 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-remote-backlog-handoff.test.sh: 16 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-teardown.test.sh: 84 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-test-lib-wait.test.sh: 3 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/lib.sh: 8 line(s) added by the validated change are absent from the candidate
  (exit 3)
```

Adding `--candidate-base origin/main`, which resolves this candidate's own base to `74230fc`, reports four of those paths with lower counts.
The fifth, `tests/lib.sh`, and the extra counts elsewhere are copies of lines the TRUNK itself removed, which a faithful replay onto that trunk could not have produced either, so the base is what tells them apart from content the rebase lost.
An earlier revision of this check instead named `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` as resurrected content; measuring the candidate against its own base shows that line came from the trunk, so it was a false positive rather than a loss.

## Reproduction 2: hunks dropped inside surviving paths

Upstream `kunchenguid/firstmate` PR 2010, head `352c5691`, base `main` at `74230fc`.
The rebase dropped the pipeline's own accepted review-fix hunks.
Path footprints alone do not detect this: the two contributions touch nearly the same file set, so only a content-level comparison sees it.

```
$ bin/fm-rebase-equivalence.sh --repo . \
    --validated-base ed376cf --validated-head d459e94 --candidate-head 352c5691
REBASE-EQUIVALENCE: DROPPED 7 path(s) lost validated content
  dropped-content      AGENTS.md: 1 line(s) added by the validated change are absent from the candidate
  dropped-content      bin/fm-attempt.sh: 7 line(s) added by the validated change are absent from the candidate
  dropped-content      bin/fm-spawn.sh: 4 line(s) added by the validated change are absent from the candidate
  dropped-content      bin/fm-teardown.sh: 12 line(s) added by the validated change are absent from the candidate
  dropped-content      docs/architecture.md: 1 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-brief.test.sh: 10 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-teardown.test.sh: 25 line(s) added by the validated change are absent from the candidate
  (exit 3)
```

`bin/fm-attempt.sh`, `bin/fm-teardown.sh`, and `docs/architecture.md` are exactly the three the by-hand comparison found.
The four others are counted because this comparison names no candidate base, so every copy the validated head holds is required; the request-derived base is what separates a copy the trunk removed from a copy the rebase lost.

## Discrimination: the same validated head, rebased faithfully, passes

A refusal is only evidence if the check also clears a correct rebase.
Validated head `d459e94` was rebased onto a later trunk commit in a scratch clone with no conflicts, producing `ac22a2b`:

```
$ git rebase --onto ab6f98f ed376cf   # in a scratch clone, at d459e94
Successfully rebased and updated detached HEAD.
$ bin/fm-rebase-equivalence.sh --repo <scratch> \
    --validated-base ed376cf --validated-head d459e94 --candidate-head ac22a2b
REBASE-EQUIVALENCE: PASS validated content is carried by the candidate
  (exit 0)
```

Adding `--candidate-base ab6f98f` reports the same `PASS`.
That both forms clear it is the discrimination that matters, because the same validated head is refused above.
Adding a further commit on top of that rebase, standing in for a pipeline fix made after validation, still passes (exit 0): the check refuses loss, never growth.
That property is what lets a worker compare its local validated head against a pushed head the pipeline legitimately moved on from.

## What the candidate's base adds

Removals are the one place two heads alone cannot settle the question.
A line the trunk added independently is indistinguishable from a validated removal the rebase undid when only the two heads are counted, and boilerplate makes that collision ordinary: a bare `fi`, `done`, or closing brace occurs many times in one shell file.
An earlier revision of this check made exactly that mistake on reproduction 1.

Measuring the candidate against its own base separates the two, which is why the base is fetched from the request rather than read from a local ref.
Without any base the check still refuses a line the validated change removed from a path entirely, which is the shape both reproductions took, and stays silent about counts it cannot attribute to the rebase rather than to the trunk.

Additions are measured against the validated head's own copy: the candidate must hold at least as many copies of each line as that copy holds.
Requiring only what the change NET ADDED fails open whenever the file already held more copies than the change added, because the copies that were always there already satisfy it; a hunk adding one more `guard` to a file that already had two then vanishes unnoticed.
The one relief is a copy the trunk itself removed, which a faithful replay onto that trunk could not have produced either, so with a base the requirement is the lesser of what the validated head holds and what a replay onto that base would produce.
That relief is what keeps the deliberate clearances intact: content the trunk supplied independently is still content that landed, and a trunk that thinned out a boilerplate line does not read as loss.

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

`tests/fm-rebase-equivalence.test.sh` (35 assertions) builds every fixture commit by commit rather than running `git rebase`, so a scenario means exactly one thing.

Refusals: a whole path present at the validated head and absent from the candidate; hunks lost inside a surviving path; a dropped hunk whose lines all already occur in the file, in both count directions; a validated line removal undone, both with and without a candidate base; a validated file deletion resurrected; a binary path the candidate lacks entirely.
Each asserts the exit status, the `DROPPED` verdict, the direction, and the naming of the losing path.

Clearances: a faithful rebase whose validated lines all shifted position because the trunk edited around them; a hunk the trunk landed independently so the rebase had nothing left to apply; a line the trunk added that matches one the validated change deleted; a path whose tracked name globs onto its siblings; content added after validation; whitespace-only churn.

The forge cases keep each candidate only under a request head ref in a bare fixture repository, cloned with `--no-local` so the worker cannot hold those objects for free.
Any verdict other than could-not-observe there is itself proof the fetch ran: a dropping candidate is refused and a faithful one passes.
`url.<local>.insteadOf` lets the check reach a fixture forge through the exact https URL it derives from a request, so the identity rule, the request-derived base, and the request-derived validated base are all exercised without a network.
The collision is constructed rather than argued: the worker's own `origin` holds a request 7 that would clear the comparison while the URL names a repository the worker cannot reach, and the check reports could-not-observe rather than reading either verdict off the wrong repository.
A companion case pins the stale-trunk hazard by advancing the fixture forge's trunk after the clone: the base fetched from the request clears the faithful rebase that the worker's own `origin/main` would refuse.

Could-not-observe, each of which a check that treated an unusable input as "nothing to do" would report as a pass: an unresolvable ref, a missing directory, a directory that is not a git repository, a missing required argument, an empty validated contribution, a binary path that changed, a request head that cannot be fetched, an unparseable request, a request whose base branch the forge will not name, a base branch that cannot be fetched, a bare request number that can name no base, a candidate remote that is not the request's repository, two candidates named at once, and an unresolvable candidate base.
A binary path whose blob is identical is still a sound observation and passes.
One case pins that every fetch is issued with `GIT_TERMINAL_PROMPT=0`, since a credential prompt would hang with no verdict line rather than refuse.
A final case asserts every outcome prints a verdict line and exits with that verdict's own status, so a caller can tell "compared and passed" from "never ran".

`tests/fm-brief.test.sh` pins the gate in the generated no-mistakes brief: the script's path, the pass verdict as the only clearance, the `--candidate-pr` form, both `blocked:` reports, and the absence of any instruction to name a pushed head or a trunk from the worker's own clone.
