---
name: paired-review
description: >-
  Agent-only protocol for running high-blast-radius implementation work as a pair - a driver and a navigator launched together - exchanging directly through a shared file instead of through firstmate.
  Use before dispatching a database migration, a contract or schema change, a subsystem deletion or relocation, or any ship task the captain names as paired, and while supervising or deciding an escalation from a pair already under way.
  Also use before dispatching a bug or regression diagnosis, which runs as one worker rather than a pair.
user-invocable: false
metadata:
  internal: true
---

# paired-review

This skill is the single owner of the paired implement-and-check protocol.
It exists because firstmate supervises several threads at once, so relaying every exchange between the two workers makes firstmate the latency bottleneck and the pair stalls waiting for a firstmate turn.
`AGENTS.md` section 1 keeps the narrowed communication rule always loaded, section 7 keeps the dispatch trigger, and section 13 keeps the load condition.

## This is pairing, not review

The two roles are the **driver**, which writes the code, and the **navigator**, which forms and holds the independent view of where the work belongs.
Use those two names everywhere, in this skill and in both briefs.

Never call the navigator a reviewer.
That word imports a post-hoc model - a reviewer waits for finished work and a diff - and three of the four gates below have no diff to look at.
That is exactly why the protocol exists: the direction error it was built to catch appears long before a diff does.
An agent told it is the reviewer will sit idle until there is something to review, which defeats the whole design.

## When to pair

Pair only high-blast-radius implementation work:

- a database migration,
- a change to a contract or a schema,
- deleting or relocating a subsystem,
- any task the captain names as paired.

Do not pair routine work.
A pair roughly doubles the token cost of the task and adds a second supervision chain to keep alive.
The trade is worth it only when re-doing the work would cost more than checking it, which is what the four triggers above have in common: a wrong direction there is not a patch but a rebuild.

## A diagnosis is not paired work

Pairing applies to implementation work.
A bug, a regression, or a crash-loop is diagnosis work and takes the diagnose-then-fix shape below: one worker, root cause first.
A navigator's contribution is an independent view of where the work belongs, and until a root cause exists there is no "where" to hold a view about, so a second agent only adds a second guess to the evidence the first is still gathering.
The risk a bug carries is a wrong root cause rather than a wrong layer, and sequence guards that where parallelism cannot.

Firstmate loads its own `diagnostic-reasoning` skill before scoping a reported bug; skipping it is how firstmate once reached for this protocol on a production crash-loop by reflex.
That skill governs how firstmate reasons about the bug and this section governs only the dispatch shape, so each keeps its own contract.

1. **One worker, handed the diagnosis skill by absolute path.**
   Its brief names `.agents/skills/diagnosing-bugs/SKILL.md` under firstmate's tracked code root, written out in absolute form, and requires it to be read and followed.
2. **The root cause is the whole deliverable.**
   The worker publishes it and stops, leaving the fix unwritten.
3. **The root-cause gate: firstmate judges the root cause before any fix action, on every diagnosis task in every project.**
   Confident, firstmate authorises the fix immediately; otherwise it escalates the root cause and waits.
   The captain gets the report either way, so the gate costs the captain a wait rather than visibility.
4. **Investigation itself needs no permission.**
   Only action on the system waits.

The root-cause document carries the reproduction, the causal chain with `file:line` per link, an explicit disconfirming check, the separation of initiating trigger from masking condition from visible symptom, and the counterfactual.
That standard is also the confidence test: all five present and holding is confidence, and any one of them missing, hand-waved, or resting on a plausible story rather than the source calls for the escalation instead.
A destructive, irreversible, or security-sensitive fix goes to the captain however certain the cause is, as does a fix direction that would expand the accepted product or engineering contract under the existing `ask-user-authority` boundary - which a diagnosis often implies, on one such task whether to retire a boot-time service entirely.
Any hypothesis firstmate hands the worker is labelled as something to confirm or refute against the source, never as a finding.
Once the captain has answered, the implementation that follows is ordinary ship work and pairs only if it independently meets the triggers above.

## Launch both sides at the same time

Dispatch the driver and the navigator together, each in its own isolated copy, before either has read anything.
The navigator must reach its own conclusion about scope and layer BEFORE it reads the driver's plan.
Reading the plan first anchors the navigator to the driver's conclusion, and an anchored navigator will not catch a direction error - it will only check the execution of a direction it has already accepted.
This is the same reason a two-axis code review runs its axes as independent parallel readers rather than feeding one axis's conclusion into the next.

The navigator needs its own task id because spawn, worktree, state, and status are all per task id; `<task-id>-nav` is the conventional form.
Record both sides under the same backlog work item rather than filing the navigator as a second work item.

## Default routing

These are defaults with their reasoning, not hard constraints, so a future dispatch can pick correctly when a task does not fit the usual shape.
An explicit per-task captain choice always overrides both.

- **Navigator: the pi runtime with an explicitly named Codex/GPT-family model.**
  The navigator checks work against a scope and a set of rules that are already written down, rather than doing open-ended design, so it does not need the strongest model.
  Where a home carries a standing rule naming the exact model for an autonomously launched Codex/GPT-family worker on pi, follow that rule; this default is consistent with it rather than an exception to it.
- **Driver: the claude runtime, on opus or sonnet chosen by the task's complexity.**

Resolve both into concrete profiles through `AGENTS.md` section 4's routing precedence and `harness-adapters`; these defaults are the best-fit input to that resolution, never a bypass of it.

## The scope and seam statement

Both members of the pair read one shared statement of scope and seam assumptions, so they start from one map instead of two private ones.
It is the `{SCOPE}` section every ship and scout brief carries by default; `bin/fm-brief.sh`'s header owns what firstmate writes into it.
Write the same statement into both briefs and cite every firstmate-home path in absolute form, because a home-relative path resolves to nothing inside a worker's own copy.

The stated scope and seam assumptions are part of the accepted contract, so widening or correcting them is an escalation, never something the pair settles between themselves.

## The four gates

1. **Independent read, at launch.**
   The navigator reaches its own conclusion about where the work belongs, from the brief and the code, without reading anything the driver has written.
   What guides it here is its own investigation of the codebase, plus the home's design-vocabulary skills for reasoning about module boundaries.
2. **Plan gate, before the driver edits any code.**
   The driver publishes a file-level plan - which files, which layer, what dies, what moves, what is created - and the navigator compares it against the conclusion it already reached.
   Challenging that plan is the navigator's whole task at this gate, so hand it the home's grilling skill, which is written for stress-testing a plan or a decision rather than judging finished code.
   This is the cheapest gate and the one that pays for the whole protocol: a wrong-layer direction error is visible from a twenty-line plan in about two minutes, and invisible at PR time under hours of work already built on it.
   This gate blocks: the driver does not edit code until the navigator's plan-gate entry lands.
3. **Milestone gates, at points the driver declares.**
   The same challenge posture, applied to direction only, never line by line.
   These do not block: the driver keeps working while the navigator reads, and treats a finding as a mid-course correction.
4. **PR gate, the full review of the finished work.**
   A two-axis code-review skill fits here and only here, and it is a reference the navigator consults rather than a procedure it executes literally.
   Two of its assumptions do not hold in this fleet, so state both in the brief and do not try to satisfy its own setup steps: it expects a fixed point supplied by a user, where here the fixed point is the branch's merge-base with the default branch, and it looks up the originating spec in a configured issue tracker, where here the spec source is the task brief and firstmate supplies it.

## The four structural questions every navigator brief carries

A navigator given a checklist checks the checklist, not the change.
So every navigator brief carries two things: the task-specific high-consequence checks, and these four structural questions, fixed and unchanged for every paired task.

1. **Was the stated reason delivered?**
   The brief or decision record says why this shape was chosen over the alternatives.
   Did the implementation achieve that reason, or only its mechanical part?
2. **Where did the coupling go?**
   If the task removed a dependency, did it disappear, or move somewhere else?
3. **Does this add another instance of a shape this repo has already been burned by?**
4. **What did the brief not specify that the implementation had to decide anyway?**
   List those decisions.

The four are fixed, and answering all four is the navigator's stopping rule at that gate.
Being bounded is the point: the captain rejected an open "what else is wrong here?" because it aims at nothing and leaves the navigator no stopping rule, so it wanders into style, unrelated files, and speculation at a round trip each.

Why this exact set, recorded so a later session keeps the questions sharp rather than treating them as boilerplate:

- Questions 1 and 2 each independently catch the failure that produced this rule.
  One PR's decision record chose registration-time contribution because `HasData` cannot survive a lazily loaded domain, and the implementation then put the trigger in `Program.cs`, which cannot survive one either.
  The stated reason went undelivered, and the coupling moved rather than disappeared: core stopped naming domains and the host started naming the feature.
  Firstmate had written three precise checks for that gate, and the navigator checked exactly those three and passed.
- Question 3 is the cheapest, and on that same PR would have flagged a second boot-time row creator three lines below the one that crash-looped production the same morning.
- Question 4 is bounded because the decisions a worker made on its own are a finite list.

The four exist because a checklist cannot reach the destination: a navigator is pointed at a diff, and a diff shows what changed, never whether the change moves toward where the work is going.
Across one day of pairs on this fleet, 2026-07-31, the pairs caught real code defects unaided - a committed NUL byte, a validation rule enforced server-side but not client-side, a whitespace-predicate mismatch - and missed both architectural direction problems, which the captain caught.
More precise checks narrow the aperture rather than widening it, which is why the destination stays firstmate's own to hold.

## The shared exchange file

The pair exchanges through one durable file at `<firstmate-home>/data/<task-id>/pair-log.md`, in the driver's task data directory, never by messaging each other's panes.
Two reasons, both load-bearing:

- Every exchange stays on disk, so firstmate reconstructs the reasoning asynchronously at its own pace without being in the loop.
- Pane messaging carries known delivery hazards this fleet has already hit - a submit that reports failure after in fact being queued or delivered, documented for the Herdr backend in `docs/herdr-backend.md`, and `bin/fm-send.sh`'s own contract for what a steer can and cannot carry.

Name the absolute path in both briefs, and state in both that this file and the worker's own status file are the permitted writes outside its copy, because the standard brief otherwise forbids writing outside the worktree.
Whichever side writes first creates the file.

The log carries three kinds of entry: the navigator's gate-1 conclusion, the driver's plan and milestone declarations, and the navigator's findings with the driver's answer under each.
The navigator writes its gate-1 conclusion before it reads any driver entry, even one already sitting in the log, which is what keeps its independent view independent and timestamps it so it cannot be retro-fitted after the plan.

Each navigator finding uses one fixed shape, with a finding id that is sequential and never reused:

```
## N3 - plan gate - navigator
claim: the workspace entity change is being made in the superseded App feature folder, not the module that owns it.
evidence: src/App/Features/Workspaces/Record.cs:41, tests/ModuleOwnershipTests.cs:18
```

The driver answers under each finding id, and answers every one:

```
### N3 - driver: accepted
reason: moving the change to the owning module; the ownership test confirms the boundary.
```

Wait for the other side by polling that file, not by nudging its pane: re-read it on a bounded cadence, roughly every thirty seconds for up to about twenty minutes.
If the cadence expires with no entry, append `paused: awaiting <gate> from <task-id>` and stop, and firstmate reconciles the pair.
The navigator's last act is its PR-gate entry, after which it appends `done:` and firstmate cleans up both copies together.

## One round trip per finding

A finding gets one exchange: the navigator states it, the driver accepts or rejects it with a reason.
If it is still disputed after that one exchange, both sides stop on it and escalate.
Without that bound two agents can argue indefinitely, because there is no supervisor in the exchange to cut it off.

## What the pair may never settle between themselves

Escalate to firstmate with a `needs-decision:` status line, and stop on that point:

1. A change to the accepted product or engineering contract.
   The concrete instance most likely to come up is a change to the stated scope or seam assumptions, so treat that as a named member of this class rather than something to infer.
2. Anything destructive, irreversible, or security-sensitive.
3. Any disagreement surviving its one round trip.

This is the same boundary as the standing rule that an implementation worker never answers its own finding, which `ask-user-authority` owns.
Two crewmates agreeing with each other can quietly approve a scope expansion that belongs to the captain, and that agreement is exactly what this boundary prevents: a pair reaching consensus is not the same thing as a decision being authorized.

## Navigator constraints

The navigator is read-only for the whole task.
It never edits project files, never commits, never pushes, never merges, and never writes into the driver's copy.
Its only writes are the shared exchange file and its own status file.

Reading the driver's copy IS allowed, and is a deliberate, stated exception to the usual rule that a worker stays inside its own worktree.
Say so explicitly in the navigator's brief, naming the driver's worktree path, so the navigator does not read the general rule as forbidding the work itself.

## Navigator idle discipline

The navigator's waits fall between gates, and whenever it stops on one it must declare a paused state.
A live idle agent whose last status line declares a pause is the only quiet state the supervision layer accepts; `AGENTS.md` section 8 owns the `paused:` and `blocked:` distinction and `bin/fm-watch.sh` owns the absorption rule.
An undeclared idle navigator wakes firstmate continuously for no reason, and exiting the navigator to quiet it is worse than leaving it idle: a dead agent removes the exact condition that would have absorbed the wake, and costs the cheap steering path for the next gate.

Waiting is not the navigator's default posture, only what it does between gates.
At gates 1 through 3 it has work to do with no diff in existence, and a navigator that waits for one has misread its role.

## How a skill reaches a paired worker

Firstmate's own skill store is a library: some of it firstmate loads itself, the rest it hands out per task.
A brief reaches a skill by naming its absolute path and instructing the worker to read and follow that file, the way the scout scaffold already hands out `decision-hold-lifecycle`.
Do not install skills into the target project, and do not install them into a machine-wide skill home.

The deciding reason is not obvious and is worth stating: the two sides of a pair run on different runtimes with different skill directories, so an absolute path behaves identically on both, while any install-based route would need a per-runtime location.
A skill is a markdown instruction file, so reading it by path loses nothing except the slash-command shorthand.

Known limitation, recorded with its reasoning rather than as a defect to fix: a handed-out review skill written to run its axes as parallel sub-agents degrades on any runtime where sub-agents are disabled, as pi is on this fleet by captain decision.
That navigator runs the axes sequentially in one context and loses the isolation between them.
It is an accepted trade for a navigator whose main job is checking work against an already-written scope; route one that genuinely needs the parallel form to a claude runtime instead.

## Firstmate's remaining role

Removing firstmate from the exchange moves no approval authority to the crewmates.
Firstmate still:

- dispatches both sides together and writes the same scope and seam statement into both briefs,
- writes the task-specific checks and the four structural questions into the navigator's brief, and holds the destination itself,
- hands out each side's skills by absolute path, and supplies the spec source at the PR gate,
- reads the shared exchange file at its own pace rather than gating the pair on a firstmate turn,
- decides every escalation under the configured authority, escalating to the captain where that authority requires it,
- owns the merge, and then the cleanup of both copies under the ordinary landed-work check.
