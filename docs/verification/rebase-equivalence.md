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
  dropped-content      bin/fm-teardown.sh: 39 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-remote-backlog-handoff.test.sh: 16 line(s) added by the validated change are absent from the candidate
  resurrected-content  tests/fm-remote-secondmate-lifecycle-e2e.test.sh: 1 line(s) removed by the validated change reappear in the candidate
  dropped-content      tests/fm-teardown.test.sh: 48 line(s) added by the validated change are absent from the candidate
  dropped-content      tests/fm-test-lib-wait.test.sh: 1 line(s) added by the validated change are absent from the candidate
  (exit 3)
```

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
Validated head `d459e94` was rebased onto a later trunk commit in a scratch clone with no conflicts, producing `3dc1e62`:

```
$ git rebase --onto ab6f98f ed376cf   # in a scratch clone, at d459e94
Successfully rebased and updated detached HEAD.
$ bin/fm-rebase-equivalence.sh --repo <scratch> \
    --validated-base ed376cf --validated-head d459e94 --candidate-head 3dc1e62
REBASE-EQUIVALENCE: PASS validated content is carried by the candidate
  (exit 0)
```

Adding a further commit on top of that rebase, standing in for a pipeline fix made after validation, still passes (exit 0): the check refuses loss, never growth.
That property is what lets a worker compare its local validated head against a pushed head the pipeline legitimately moved on from.

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

`tests/fm-rebase-equivalence.test.sh` (16 assertions) builds every fixture commit by commit rather than running `git rebase`, so a scenario means exactly one thing.

Refusals: a whole path present at the validated head and absent from the candidate; hunks lost inside a surviving path; a validated line removal undone; a validated file deletion resurrected.
Each asserts the exit status, the `DROPPED` verdict, the direction, and the naming of the losing path.

Clearances: a faithful rebase whose validated lines all shifted position because the trunk edited around them; a hunk the trunk landed independently so the rebase had nothing left to apply; content added after validation; whitespace-only churn.

Could-not-observe, each of which a check that treated an unusable input as "nothing to do" would report as a pass: an unresolvable ref, a missing directory, a directory that is not a git repository, a missing required argument, an empty validated contribution, and a binary path that changed.
A binary path whose blob is identical is still a sound observation and passes.
A final case asserts every outcome prints a verdict line, so a caller can tell "compared and passed" from "never ran".
