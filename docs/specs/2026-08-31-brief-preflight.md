# Brief preflight: refuse impossible work before the spawn burns a run

Status: built. Gates `gate-t1-brief-preflight-rules`,
`gate-t1-brief-preflight-spawn-gate`.
Implementation: `bin/fm-preflight-lib.sh`, hooked into `bin/fm-spawn.sh`.

## The evidence

Three briefs written on 2026-08-28/29 specified work no crewmate could do.

1. *"Move `data/command-center-roadmap.md` into `docs/`"* — `data/` is
   gitignored, so the file is not in a worktree at all, and a gitignored file
   cannot be deleted by a commit.
2. *"Fix the 68 stale briefs"* — same cause; they live under `data/` and are
   invisible to a crewmate.
3. *"Test the chain under `FM_HOME=$(mktemp -d)`"* — `fm-home-seed.sh` leases
   from the **live** treehouse pool regardless of `FM_HOME`, so a "test" run
   silently leaks a durable lease into the captain's pool.

The intake council caught all three — but only after a full cycle of two thinker
lenses and a foreign deep lens. A fourth defect reached a live crewmate: a brief
carrying the retired `>>` status redirect, whose reports the permission profile
silently refused for ten minutes while the pane looked idle.

## Why this is not the council's job

All four are **structural**. Each is decidable from the brief text, the
project's own ignore rules, and a list of known-hazardous commands, with no
model in the loop. Asking three models to notice them is both more expensive and
less reliable than deciding them, and a structural check cannot have an off day.

This is the same split the repo already makes at the Quarterdeck, where
`fm_gates_classify` adjudicates the gate ledger structurally *ahead of both
models* so an unacceptable ledger costs neither. The preflight is that move
applied to intake: the structural half of the Wardroom.

## The rules

Each rule answers one question: **can the crewmate physically do what the brief
says?**

| rule | offender | why it cannot be done |
| --- | --- | --- |
| `gitignored` | a project-relative path the project's git reports as ignored | it is not in the worktree, and no commit can add, move or delete it |
| `primary-checkout` | an absolute path under the firstmate primary checkout that is not sanctioned | the permission profile denies that tree to crewmates |
| `pool-lease` | an **invocation** of `fm-home-seed.sh` or `fm-spawn.sh`, or an `FM_HOME=$(mktemp -d)` / `FM_HOME=$TMPDIR/…` assignment | both scripts lease from the live treehouse pool whatever `FM_HOME` says, so a "test" run leaks a durable lease into the captain's pool — and pinning `FM_HOME` to a throwaway dir claims an isolation it cannot provide |
| `status-redirect` | a `>` / `>>` into a `.status` path, or a `.status` path named without `bin/fm-status.sh` | the permission profile silently discards the report, so the pane just looks idle |

Two supporting decisions:

**git is the authority for `gitignored`.** The rule does not re-implement ignore
matching; it asks `git check-ignore` in the project, without `--no-index`, so a
*tracked* path that some pattern happens to match answers "visible" — which is
the honest answer for a crewmate, because a tracked file is in its worktree.

**The sanctioned set for `primary-checkout`** is exactly what `bin/fm-brief.sh`
itself emits, and nothing wider: the home root and its `state` dir as
`FM_HOME=` / `FM_STATE_OVERRIDE=` pin them, `bin/…` (helper scripts the brief
hands the crewmate to *run*), `state/<id>.*` (this task's status file), and
`data/<id>/…` (this task's brief and report dir). `data/` or `state/` belonging
to **another** task is another task's material — which is how "fix the 68 stale
briefs" got written — and is refused.

A glob is evaluated on the text before its **first glob character**, and where
that lands mid-segment the last segment is only a prefix. `state/<id>.*` is
sanctioned, because the `.` is a boundary the glob cannot cross back over and it
is the shape real status and meta files have; `state/<id>*` and `data/<id>*` are
not, because both also match `<id>-other`. Truncating at the *segment* boundary
instead — an earlier cut — dropped `<id>.*` entirely and refused the very
`state/<id>.*` the refusal message advertises as sanctioned.

## The refusal names the offender

A preflight that says "invalid brief" costs another cycle to diagnose, which is
half of what it exists to remove. Every finding carries the exact path or
command, the reason, and the line:

```
======================== PREFLIGHT =========================
REFUSED: fm-spawn for task pfgit-k3 - the brief asks for work the crewmate
cannot see or safely touch. Each offender is named below.
  [gitignored] data/command-center-roadmap.md
      gitignored in <project>, so it does not exist in a crewmate's worktree
      and no commit can add, move or delete it - line 4
Fix the brief at: <path>
Captain bypass (loud, logged): FM_PREFLIGHT_OVERRIDE=1
===========================================================
```

## Fail closed, but not noisily wrong

False refusals are worse than no check: they train everyone to reach for the
override, and then the gate protects nothing. So a path that merely *resembles*
an offender is not a match, and each near-miss is proven by a committed fixture:

- `/Users/x/firstmate-notes/a` is not under `/Users/x/firstmate`. The character
  after the root must be a path separator, not any character.
- `fm-spawn.sh.bak` and `my-fm-spawn.sh` are not `fm-spawn.sh`. Both boundaries
  of the script name are checked.
- The scaffold's own **warning** about the `>>` redirect carries no `.status`
  target after the operator, so it does not match.

### Invocation, not mention

The pool-leasing scripts are also ordinary subjects of work: *"add a preflight
to `bin/fm-spawn.sh`"* is a legitimate brief, and refusing it would make this a
gate nothing gets past. The rule therefore matches an **invocation form**, and
every form must be written **as code** — inside a backtick span or a fenced
block, which is how a brief that means "run this" writes it, and how the
standard scaffold writes every command it hands a crewmate. Inside that context:

- an interpreter runs it — `` `bash bin/fm-home-seed.sh …` ``
- the path is executed — `` `./bin/fm-spawn.sh …` ``
- command position with arguments — `` `bin/fm-spawn.sh <id> <repo>` ``

and not a mention:

- `` `bin/fm-spawn.sh` `` alone in a code span, with no arguments
- *"a preflight in bin/fm-spawn.sh before the wardroom gate"*
- *"- bin/fm-spawn.sh is the spawn entry point"*
- *"the flagship bash bin/fm-spawn.sh wrapper launches every crewmate"*
- *"for reference, ./bin/fm-home-seed.sh is the file you are editing"*
- *"Run bash first, then `bin/fm-spawn.sh`"* — the interpreter belongs to the
  sentence, not to the code span, so it is looked for **inside** the span only

The last three are why the code-context requirement covers the interpreter and
`./` forms too, and not only the bare one. An earlier cut exempted them on the
reasoning that *nothing else writes them* — but English does: a sentence can put
the word "bash", or a relative path, immediately before a script name while
saying the opposite of *run it*. In prose there is no reliable signal at all;
inside a code span there is.

The cost of that line is a false negative: a command written as bare prose,
*"run bin/fm-home-seed.sh sm-triage yourself"*, is not matched. That is covered
from the other side by the `FM_HOME` half of the rule, which needs no code
context because `FM_HOME=$(mktemp -d)` means only one thing wherever it appears
— and it is the truer signal for the third defect anyway, whose brief said
*"test the chain under `FM_HOME=$(mktemp -d)`"* without naming a script at all.

Only the **dynamic** throwaway constructs count there: `$(mktemp …)` and
`$TMPDIR`. A literal `/tmp/…` or `/var/folders/…` path was in an earlier cut and
had to come out — it is not evidence of the belief, it is just where a home
happens to live, and it refused the standard scaffold outright whenever
`FM_HOME` sat under the system temp dir. A rule that fires on the scaffold is a
rule nobody keeps.

### The known false-refusal class

Referencing is the standard the `gitignored` rule is written to, not acting-on,
because deciding "is this path a work target or a citation?" means parsing the
verb out of prose — and a rule that guessed there would be wrong in both
directions instead of one. So two legitimate briefs are refused:

- one that must **cite** an invisible path: a brief about this preflight, or one
  quoting a past defect;
- one that merely **mentions** a build or dependency artifact — `node_modules/…`
  in a JS project, `target/…` in a Rust one — which is ignored, but which the
  brief was never asking to commit.

That is the honest cost of failing closed, and it is bounded: the refusal names
the path, so it is one loud, diagnosable cycle, never a silent one. Two ways
through: paraphrase the reference (*"a path under the gitignored `data/` tree"*),
or use `FM_PREFLIGHT_OVERRIDE=1`, which is loud and logged.

The alternative — a warning rather than a refusal — was rejected because a
warning on a spawn nobody is watching is exactly how the fourth defect reached a
live crewmate and sat there for ten minutes.

## Where it runs

`bin/fm-spawn.sh`, immediately after the brief-exists check and **ahead of** the
intake council:

- it needs no model at all, so it should never cost a council cycle;
- the council exempts scouts, and the third defect above is exactly a scout
  ("test the chain"), so the preflight must cover them;
- nothing is created before it — no pane, no worktree, no meta.

Secondmates are exempt: their brief is a charter and their home *is* a firstmate
home, where `data/` and `state/` are theirs to operate.

A project directory that is not a git repo is **not** "cannot tell": a tree with
no ignore machinery hides nothing, so the `gitignored` rule is simply not
applicable and the other three still run. This mirrors `fm_gates_classify`'s
`NOGATES`.

## Gates

| gate | proves |
| --- | --- |
| `gate-t1-brief-preflight-rules` | one committed fixture per rule is refused with the offender named; the clean fixture, the lookalike fixture, and the real ship and scout scaffolds from `bin/fm-brief.sh` all pass; a non-git project runs the other three rules; a missing brief is refused |
| `gate-t1-brief-preflight-spawn-gate` | `fm-spawn` refuses before anything is created, ahead of the wardroom, for ship and scout alike; a clean brief gets through; the override is loud; secondmates are exempt |

The fixtures live in `tests/fixtures/preflight/`. `clean.md` and `lookalike.md`
are the two that must **pass**, and they are what keeps this from becoming a
gate nothing gets past — a failure mode this repo has already lived through.

## Not in scope

- **`bin/fm-intake.sh` is not hooked.** Running the preflight there too would
  save the council's model calls on an impossible brief, which is real value,
  but it changes the council's contract and belongs in its own slice. The spawn
  is the chokepoint that burns the run, and that is what this closes.
- **Promoted scouts.** `bin/fm-promote.sh` flips `kind=` in place with no
  `fm-spawn`, so a promotion carries its worktree past this gate exactly as it
  already carries it past the wardroom. Same queued follow-up.
