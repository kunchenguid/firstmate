# Rebase-equivalence verification

Repeatable evidence that [`../../bin/fm-rebase-equivalence.sh`](../../bin/fm-rebase-equivalence.sh) detects a rebase that drops validated content and clears one that does not.
The predicate, its verdict vocabulary, and why it is neither a tip-to-tip diff nor a merge-result comparison are owned by that script's header and `--help`; this page records evidence only.

> ## THE DEFECT THIS PAGE IS ABOUT IS STILL OPEN
>
> A validation pipeline's push-time rebase can silently drop content the pipeline already validated, so an opened request can misrepresent what was judged.
> That happened twice on 2026-08-09 and **nothing in this repository prevents it happening again.**
>
> What ships here is a **diagnostic**, invoked deliberately by firstmate. It reports; it does not gate.
> No automatic check refuses, blocks, or delays a request on this, and neither `bin/fm-pr-check.sh` nor `bin/fm-pr-merge.sh` can fail because of it.
>
> **What the diagnostic detects,** when it is given both heads: content the validated head carried that the pushed head does not, per path and with the direction of the loss, including whole paths, hunks inside surviving paths, undone deletions, and dropped file modes.
>
> **What it does not prevent:** anything. It is not in the delivery path. A dropping rebase reaches a reviewer exactly as it did before unless somebody runs the diagnostic.
>
> **Why an automatic gate was withdrawn rather than fixed.** It needs the validated head, and that head is destroyed at push: the pipeline overwrites `head_sha` with the pushed head in **68 of 68 pushed runs**, with no exceptions, so after a push no retained record holds it.
> Three sources were tried and each failed differently, all measured rather than argued.
> The worker's own head is older content, because a run commits its fixes onto its copy of the branch.
> `submitted_head_sha` predates the run's own fix commits, so an accepted fix that rewrote a line reads as that line being dropped - it refuses 6 paths on a real run whose review fix legitimately rewrote them, and 62 of 69 pushed runs are exposed to it.
> A watcher snapshot taken before the push narrows that to one poll interval rather than eliminating it, and a stale snapshot refuses a good push with a false accusation indistinguishable from a true one; worse, a missing snapshot refused intake, and because `bin/fm-pr-merge.sh` routes through `bin/fm-pr-check.sh` the request then became permanently unmergeable with no recovery path.
> A safety mechanism that can silently and permanently destroy delivery is worse than the defect it was built to prevent.
>
> **What would actually close this:** the pipeline retaining its pre-push head, so the content it validated remains nameable after the push.
> That is a change in the validation tool, not in this repository, and until it exists the defect stays open.
> The defect is recorded as backlog item `rebase-drop-defect-remains-unprevented`, filed by firstmate with the full history and its closing condition, and blocked by `unenforced-commitment-register` so it migrates into that register when the register lands.
> It is not in the register, because the register does not exist yet.

Date: 2026-08-10.
Git: 2.53.0.
ShellCheck: 0.11.0 (the pin `bin/fm-lint.sh` enforces).

## Why this check exists

The `no-mistakes` pipeline rebases a branch onto its target immediately before pushing it.
Twice in one day that rebase produced a pushed head that had silently lost content the pipeline had already validated, and the opened PR misrepresented what was judged.
Neither loss was reported by any pipeline signal; both were caught only by comparing content by hand.

The push step itself is not reachable from this repository.
`no-mistakes` is a single compiled binary (`~/.no-mistakes/bin/no-mistakes`, 24 MB, v1.40.3 at the date above), and its configuration schema exposes agent selection, timeouts, per-step `auto_fix` counts (including `rebase`), intent extraction, and test-evidence storage - no custom step, pre-push hook, or validation plugin.
So this repository owns the comparison, and it runs only when firstmate or a maintainer deliberately invokes it: nothing in the delivery path calls it, and neither `bin/fm-pr-check.sh` nor `bin/fm-pr-merge.sh` can refuse, block, or delay a request because of it.

## Where the validated head comes from

The worker's own branch head is not the validated content, and the check never falls back to it.
A run commits its own fixes onto the pipeline's copy of the branch, so the worker's head is the OLDER content: a fix that rewrote a line the branch added, `foo(a)` becoming `foo(a, b)`, would read as that line having been dropped by the push.
The pipeline records what it submitted and what it pushed, per run, in its own database at `~/.no-mistakes/state.sqlite`, table `runs`.
Those columns were established by reading real completed runs rather than from their names, because an earlier version of this page asserted the meaning and filed an all-empty schema block as its evidence, which proved nothing.

Read across all 116 runs in a live database on 2026-08-10, and cross-checked against two pull requests whose heads were independently verified in git:

```
$ python3 -c "...sqlite3 'file:~/.no-mistakes/state.sqlite?mode=ro'..."
runs total 116; pushed 68; never-pushed 48
  of pushed: head_sha == last_pushed_sha : 68
  of pushed: head_sha != last_pushed_sha : 0
  of never-pushed: head_sha == submitted : 20 of 48
```

- `submitted_head_sha` is the head the worker submitted when the run started, and is never rewritten.
- `head_sha` is the pipeline's LIVE head: it advances with the run's own fix commits, and at push time it is overwritten with the pushed head. 68 of 68 pushed runs have `head_sha == last_pushed_sha`, with no exceptions.
- `last_pushed_sha` is the pushed, post-rebase head, and is empty until a push happens.

The two verified rows, whose heads match the reproductions below exactly:

```
fm/cfvc-13-attempt-budget   submitted d459e942966f  head 352c56912080  last_pushed 352c56912080   pr 2010
fm/fork-trunk-serial2-base-red submitted 646f2390494f head eabefe425ba3 last_pushed eabefe425ba3  pr 2009
```

**This bounds what the comparison can prove, and the bound is stated rather than implied.**
Because `head_sha` is overwritten at push time, the pre-rebase head carrying a run's own fix commits is not retained anywhere once the push completes.
So after a push, NO retained column is the validated head.

### `submitted_head_sha` is not the validated side, and was measured to prove it

It is the obvious candidate, and the field name is exactly what it sounds like, so this is recorded explicitly to stop it being proposed again.
It predates the run's own fix commits, so an accepted fix that REWRITES a line the branch added reads as that line having been dropped by the push.

```
$ bin/fm-rebase-equivalence.sh --repo . --validated-base ed376cf \
    --validated-head a2952d0 --candidate-head 352c5691    # submitted vs pushed
REBASE-EQUIVALENCE: DROPPED 6 path(s) lost validated content
```

That run's own accepted review fix legitimately rewrote those lines, and 62 of 69 pushed runs have `submitted_head_sha` differing from `last_pushed_sha`, so this refuses the common case rather than an edge.
A gate that refuses the common case gets switched off, and then it protects nothing.

Driven end to end through the intake gate that was later withdrawn, on a wholly faithful push - the run's accepted fix rewrote `foo(a)` into `foo(a, b)` and the push carried the fixed line - the two sources diverged completely:

```
submitted_head_sha source : exit 1, "DROPPED 1 path(s) lost validated content", watch NOT armed
snapshot source           : exit 0, "armed: state/task-a.check.sh"
```

### The validated head was snapshot while it still existed, and that machinery is removed

Nothing described in this subsection runs any more; it is recorded because someone will otherwise propose it again.
Firstmate's watcher recorded the last `head_sha` each run had while it had NOT yet pushed, keyed by run id, with the observation time - a tail rather than a trigger, because poll timing cannot reliably catch the exact pre-push boundary.
Firstmate took it rather than the worker, because the party being checked must not supply the evidence; it was a mechanical copy of the pipeline's own record about its own run.
It was withdrawn with the gate and the machinery deleted: nothing consumed the snapshot once the gate went, so a watcher tick spawning an interpreter and a database read every fifteen seconds wrote files nobody read into a directory nothing pruned.
Wiring the diagnostic to read it instead was rejected, because a stale snapshot would put a silently wrong head into a report a human treats as considered, and a diagnostic that carries a wrong head is worse than one that reports less.

### What the diagnostic reads instead

There is no snapshot, so the diagnostic is handed the commit id directly and obtains that object from the pipeline's own repository, which is an ordinary local-path remote in every initialized clone:

```
$ git remote -v
no-mistakes  /home/shane/.no-mistakes/repos/5f306883d81c.git (fetch)
no-mistakes  /home/shane/.no-mistakes/repos/5f306883d81c.git (push)
```

`--validated-remote` fetches the named commit from there by object id into `refs/fm-rebase-equivalence/validated/<oid>`.
A local-path remote answers a bare object id even when no ref points at the commit any more, which is what the gate looks like once its branch has moved past the validated head; the regression suite constructs exactly that state by pushing the validated head to a scratch ref in a bare fixture repository and then deleting the ref.
Only a full commit id is accepted with that flag, because a symbolic name would resolve in the worker's clone and hand back the local head the flag exists to stop trusting.
An object id is the content, so once it resolves it names the run record's commit and nothing else, whether the fetch carried it here or this clone already held that exact object; git's own fetch relies on the same identity and treats an already-present object id as satisfied without contacting the remote.
The flag is therefore how the id is obtained and not provenance, and the script header and its `--help` both say so in those words: it establishes that the caller named a full object id and that the id resolves here, never that the head came from the pipeline.
A head that cannot be named or obtained at all is `CANNOT-OBSERVE`, and there is deliberately no fallback to a local ref.
The ref that carries the fetched object is released from a trap armed before the fetch that creates it, so no refusal and no signal can leak it; the candidate and base refs are deliberately kept, because they are keyed by request number rather than object id and their persistence is the evidence below that the fetch ran.

Sync-then-compare was rejected on evidence.
`no-mistakes axi sync` moves the local branch TO the pipeline-pushed head with reset semantics, so after syncing the local head IS the candidate and the comparison would be a head compared against itself.
That trades a false refusal for a structurally vacuous gate, which is worse, and the sync is guarded and legal only when `branch_sync.next_action` offers it, so it cannot be a precondition of a check at all.

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
With the trunk in hand the validated head's own base is the same fork point off the same trunk, so `--validated-base` is optional in this form and an invocation names only the validated head from the run record, the `no-mistakes` remote it lives on, and the PR URL.

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
`-oBatchMode=yes` is appended to whatever `GIT_SSH_COMMAND` the caller already exports rather than supplied only as a default, so a client that does not accept OpenSSH options fails into `CANNOT-OBSERVE` instead of being used verbatim and left free to hang.
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

Both base flags take a TRUNK ref and narrow it to their own head's fork point with `git merge-base`, so handing the same trunk to both means the same thing on both sides.
Used verbatim, a moved trunk turns every trunk-only line into a removal the validated change never made, and the faithful rebase that carries that line is then refused as resurrected content.
Narrowing is idempotent for a caller who already knows the exact fork point, so the two shapes collapse into one without changing any correct invocation, and the validated base may be omitted whenever a candidate trunk is given.

## File modes are content

A mode change emits `old mode` and `new mode` lines with no `@@` hunk at all, so a line comparison alone sees nothing and records the path as carried.
Every script in `bin/` must be executable and this repository tests file modes elsewhere, so a rebase that lands `bin/fm-new.sh` at 100644 has lost validated content as surely as a dropped hunk, and a chmod with no content edit beside it would otherwise report `PASS` on scripts that cannot run.
Each footprint path's mode is therefore read from all three commits with `git ls-tree`, and a mode the VALIDATED CHANGE set - one that differs from the mode at its own base, which includes a file it added outright - must still be set at the candidate, reported as `dropped-mode` with both modes named.
A mode the validated change never touched belongs to the trunk, so a chmod the trunk made on its own is not read as loss.

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

## The gate that was built here, and withdrawn

This section is kept because the reasons it failed are the reasons no gate ships, and someone will otherwise propose it again.
The comparison was made where both facts are readable and where the authority to land sits.
A worker cannot see the validated bytes: they are in the pipeline's gate repository, not its clone.
Three separate defects reduced to that one structural fact, and the third of them left the check able to report `PASS` without ever comparing, so the gate moved to `bin/fm-pr-check.sh` rather than being patched a fourth time.

The run-record reader that fed this gate was removed with it, since nothing consumed it afterwards.
Its outcome WAS three-valued, and none of this runs any more:

- bytes carried: intake proceeded and armed the merge watch as before;
- bytes dropped: intake refused, named the losing paths, and did not arm the watch;
- no recorded run: passed through untouched, since the request was never produced by a pipeline rebase - `direct-PR` delivery has no run row at all;
- comparison unavailable: refused, so that a warning followed by an armed watch could not read as a pass.

Watched red before it was trusted green, against one reconstructed dropping rebase, with the gate the only difference between the two runs:

```
$ <pre-gate bin/fm-pr-check.sh> task-a https://github.com/o/r/pull/7
armed: state/task-a.check.sh
  (exit 0 - the merge watch was armed although the push had dropped the validated fix)

$ bin/fm-pr-check.sh task-a https://github.com/o/r/pull/7
REBASE-EQUIVALENCE: DROPPED 1 path(s) lost validated content
  dropped-content      core.sh: 1 line(s) added by the validated change are absent from the candidate
error: the pushed request does not carry the content this run validated; it is not shippable as it stands
  (exit 1 - and state/task-a.check.sh does not exist)
```

Both measured incidents are refused using the pair the run record itself names, rather than a pair chosen by hand:

```
$ bin/fm-rebase-equivalence.sh --repo . --validated-base ed376cf \
    --validated-head 646f2390 --candidate-head eabefe42        # PR 2009, as recorded
REBASE-EQUIVALENCE: DROPPED 4 path(s) lost validated content
  dropped-content      bin/fm-teardown.sh: 19 line(s) ...
  dropped-content      tests/fm-teardown.test.sh: 57 line(s) ...
  (exit 3)

$ bin/fm-rebase-equivalence.sh --repo . --validated-base ed376cf \
    --validated-head d459e94 --candidate-head 352c5691          # PR 2010, as recorded
  (exit 3)
```

## The check cannot reach a verdict without comparing

Three ways it could, each now refused, and each watched failing first against the head that preceded the guard:

| Case | Before | After |
| --- | --- | --- |
| validated head resolves to the candidate | `PASS`, exit 0, indistinguishable from a real comparison | `CANNOT-OBSERVE`, exit 2 |
| `--validated-remote ""` from a wrapper whose variable was unset | proceeded to a verdict, silently using a local ref | `CANNOT-OBSERVE`, exit 2, naming the empty value |
| `--candidate-pr` with a local validated head | compared forge bytes against the worker's older head | `CANNOT-OBSERVE`, exit 2, naming the required source |

None of that narrowed what the check can still answer: a faithful rebase over a moved trunk passes, and both reproductions are still refused.

## Regression coverage

`tests/fm-rebase-equivalence.test.sh` builds every fixture commit by commit rather than running `git rebase`, so a scenario means exactly one thing, and every fixture commit is allowed to fail the suite rather than being folded silently into the next one.

Refusals: a whole path present at the validated head and absent from the candidate; hunks lost inside a surviving path; a dropped hunk whose lines all already occur in the file, in both count directions; a validated line removal undone, both with and without a candidate base; a validated file deletion resurrected; a binary path the candidate lacks entirely; an executable bit the validated change set, both alongside a content change and as a validated change made entirely of a mode; a dropped hunk in a repository whose `.gitattributes` names a `diff=<driver>` textconv, which the diffs disable because the counted copies come from `git show` and always are the raw blob - measured, counting converted lines against raw ones fails OPEN and reports `PASS` on a candidate that dropped the hunk outright.
Each asserts the exit status, the `DROPPED` verdict, the direction, and the naming of the losing path.

Clearances: a faithful rebase whose validated lines all shifted position because the trunk edited around them; a hunk the trunk landed independently so the rebase had nothing left to apply; a line the trunk added that matches one the validated change deleted; a path whose tracked name globs onto its siblings; content added after validation; whitespace-only churn; a mode the trunk set on its own that the validated change never touched; the same moved trunk ref given to both base flags, and that trunk given as the candidate base alone with the validated base derived from it.

The validated-head cases build a bare fixture repository standing in for the pipeline's own, holding the validated commit as a loose object with its ref deleted, beside a separate fixture forge that publishes the pushed head.
The pipeline's accepted fix rewrote a line the branch added, so the same comparison is run twice: against this clone's own head, which reports the pipeline's fix as `dropped-content`, and against the head the run record names, which reports `PASS`.
Running both is what makes the second one evidence rather than an absent refusal.
A symbolic `--validated-head` is refused with `--validated-remote`, which is what keeps the worker's own `HEAD` from standing in for the validated content, and an object id no side holds is could-not-observe rather than a comparison of whatever was nearest.

The forge cases keep each candidate only under a request head ref in a bare fixture repository, cloned with `--no-local` so the worker cannot hold those objects for free.
Any verdict other than could-not-observe there is itself proof the fetch ran: a dropping candidate is refused and a faithful one passes.
`url.<local>.insteadOf` lets the check reach a fixture forge through the exact https URL it derives from a request, so the identity rule, the request-derived base, and the request-derived validated base are all exercised without a network.
The collision is constructed rather than argued: the worker's own `origin` holds a request 7 that would clear the comparison while the URL names a repository the worker cannot reach, and the check reports could-not-observe rather than reading either verdict off the wrong repository.
A companion case pins the stale-trunk hazard by advancing the fixture forge's trunk after the clone: the base fetched from the request clears the faithful rebase that the worker's own `origin/main` would refuse.

Could-not-observe, each of which a check that treated an unusable input as "nothing to do" would report as a pass: an unresolvable ref, a missing directory, a directory that is not a git repository, a missing required argument, an empty validated contribution, a binary path that changed, a request head that cannot be fetched, an unparseable request, a request whose base branch the forge will not name, a base branch that cannot be fetched, a bare request number, which is refused outright for naming no repository rather than for failing to resolve a base, a candidate remote that is not the request's repository, two candidates named at once, and an unresolvable candidate base.
A binary path whose blob is identical is still a sound observation and passes.
One case pins that every fetch is issued with `GIT_TERMINAL_PROMPT=0`, since a credential prompt would hang with no verdict line rather than refuse.
A companion case pins the ssh path behaviourally rather than by grep: it exports its own `GIT_SSH_COMMAND`, points the check at an `ssh://` remote, and asserts that the ssh git actually invoked carries both the caller's own option and the appended `-oBatchMode=yes`, because keeping a caller's value verbatim would drop batch mode and reopen exactly that hang.
A final case asserts every outcome prints a verdict line and exits with that verdict's own status, so a caller can tell "compared and passed" from "never ran".
Its companion pins the cancelled run, which is the same distinction from the other side: `tr` is shimmed to sleep so the signal lands deterministically in the window after the per-path loop, and the run must print no verdict line and exit 143 rather than fall through its own cleanup to a `PASS` it never earned.

`tests/fm-brief.test.sh` pins the comparison's ABSENCE from the generated no-mistakes brief.
Asking a worker for this verdict was tried and retired: it cannot obtain either head, so the instruction could only ever report could-not-observe.
`tests/fm-pr-check-security.test.sh` pins that neither intake nor merge can block on head comparison again, on the exact state that used to brick delivery.
