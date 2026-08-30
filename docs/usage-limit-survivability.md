# Usage-limit survivability

A provider usage limit is not a crash.
It looks like one, and that is the entire problem this surface exists to solve.

When an account hits its limit, every worker on that account dies inside the same minute.
The harness exits non-zero, the validation run goes terminal with findings still awaiting, nothing is pushed, and no pull request appears.
On 2026-08-23 that shape cost roughly an hour of manual reconstruction across five workers, and the reconstruction was entirely re-derived: the cause was legible only in the pipeline step logs, which both ended on the vendor's own limit line followed by the harness's non-zero exit, while the run status said nothing but `failed`.

The same wall was survived cheaply three days later, and the difference was not skill.
It was one gauge reading taken before the wall and one written plan.
Both of those depended on a hand-written file and on a single session remembering a procedure, and neither survives a context reset or reaches a home that has never hit the wall.

This surface makes both structural.

## Shape

One command owns the data, one skill owns the procedure, and neither restates the other.

| Piece | Owns |
| --- | --- |
| [`bin/fm-usage-wall.sh`](../bin/fm-usage-wall.sh) | `headroom`, `diagnose`, and `resume`: the gauge, the verdict, and the record |
| `.agents/skills/usage-limit-recovery` | The recovery procedure, and the four facts that make it cheap |
| [`bin/fm-session-start.sh`](../bin/fm-session-start.sh) | Printing the gauge and the wall scan where they cannot be missed |
| [`bin/fm-fleet-view.sh`](../bin/fm-fleet-view.sh) | Printing the gauge at every heartbeat review |

The command's own header is the authoritative description of its behavior, flags, exit statuses, and tunables.
This document covers why the pieces are shaped the way they are.

## Why unmeasurable is a first-class verdict

`quota-axi` returns `auth_required` and unknown headroom until the operator approves local credential access once, and that approval blocks on a system dialog.
A gauge that rendered "could not read it" the same way as "plenty left" would be worse than no gauge, because it would be trusted.

So `headroom` has three provider verdicts that mean a reading was taken (`ok`, `tight`, `wall`) and one that means none was (`unknown`), and there is no code path from a failed read to a healthy verdict.
Absent, erroring, hanging, unparseable, unresolved, and unauthenticated all land on `unknown` with the concrete reason attached, and the one-time operator command is named on the line that needs it.
Nothing the report emits is ever dropped from the reading: after the account-level reading and the flagged-provider reading, every name appearing anywhere in `quota[]` at any scope, `exhaustion[]`, or `attention[]` is swept and given its own line - measured when an account-scoped row was read, unknown with its reason otherwise.
That is swept from the report's own names rather than enumerated shape by shape, because each earlier attempt closed one way a provider could be missed and left another open.
A rule about names has one gap of its own: a row whose `provider` cell is empty carries no name to sweep by.
The invariant is therefore about ROWS - every row the gauge emitted, in every table the reading consults, is either reported or accounted for as unreported with a reason - and rows the sweep cannot reach are reported as a single `unattributable-row` line.
It is enforced by one accounting pass over a single list of the tables consulted, not by a guard per table, because a guard per table is what kept reopening this: each round closed the table in front of it, and `exhaustion[]` - which no loop enumerates - went on losing rows to a sweep that dropped unnamed ones silently.
A table added upstream joins the reading by joining that list, and is accounted for from that moment.
That is what lets `unknown=0` mean everything the gauge reported was actually read.
Every unknown also carries a reason that is true of the provider it names: a provider known only through `exhaustion[]` is missing a quota row, not a measurable window, and saying otherwise would contradict the detail printed beside it.
A provider that quietly disappears is worse than one reported unknown, because the summary above it then reads as if everything measurable had been measured.

The aggregate carries that vocabulary plus one verdict a single provider cannot need, and its precedence is `wall` > `tight` > `partial` > `ok`, with `unknown` reserved for a reading nobody got.
`wall` outranks `tight` because those are different states rather than degrees of one: `tight` means a dispatch may still land, while `wall` means that provider has already stopped and every worker on it is down.
Collapsing the second into the first would leave the summary line, and the `.verdict` field a programmatic reader branches on, unable to express the single condition this surface exists to announce.
An exhausted provider reported as merely tight is a false reading, not a conservative one.

`partial` is that same rule one level up: some providers measured and healthy, others never read at all.
It is not a hedge and not an edge case - on a host where one provider is measurable and five are not, `partial` is the normal reading whenever the measurable one is healthy, so it is the mixed verdict a reader actually hits.
Folding it into `ok` would report unread providers as fine and folding it into `unknown` would discard a reading that was taken, so it stands on its own and carries the same `HEADROOM_NEXT` pointer every other actionable verdict does.

The command never passes `--allow-keychain-prompt` itself: it runs inside a session-open hook that blocks the first turn, and a blocking dialog there would cost the whole session.
`tests/fm-usage-wall.test.sh` pins each of those paths separately, including that the flag is never passed.

`tight` is presentation, not policy.
It labels a reading; it never gates, blocks, or reorders a dispatch.
Firstmate and the captain decide what runs, and there is deliberately no budgeting, scheduling, or admission logic anywhere in this surface.

Headroom is read out of `quota-axi`'s default TOON rather than its JSON, because the TOON is the surface `AGENTS.md` section 4 already makes the dispatch-facing one, and because it renders the derived per-provider reading directly rather than leaving this command to re-derive it from raw windows.
The command reads exactly the layout a floor-compliant build emits: `quota[]` for the account percentage with the window that bounds it and that window's reset, `exhaustion[]` for the runway with its own bounding window, and `attention[]` for the kind, detail and remedy of a provider with no measurable window.
The TOON block is parsed by field name out of its own declared header, so an upstream provider, window, or field addition shifts nothing; a reordered report is a test case, not a hope.
A field the header does not declare reads as absent rather than as a value, so an upstream rename leaves the row UNKNOWN instead of letting an unreadable percentage compare its way to healthy - and a renamed `provider` field leaves the whole reading unknown rather than reporting a healthy percentage nobody can attribute.
Each block resolves its own header, including a second block of the same name later in the report, so a sparse table between them cannot leave the second reading the first one's column positions.
A percentage is required to be a NUMBER rather than an integer: no observed build emits a fraction, but refusing one would blank a gauge that was fully readable.
A decimal is printed as the gauge gave it and compared as the value it is, so both thresholds mean for a fraction exactly what they say: `wall` needs the value to BE zero, so a fraction of a percent reads `tight` rather than `wall`, and `tight` is at or below `FM_USAGE_WALL_TIGHT_PCT`, so at the default threshold of 20 a reading of 20.0 is tight and 20.9 is not.
Comparing a truncated integer part would have left the threshold's definition and its behaviour describing different rules.

A `quota-axi` older than the floor `bin/fm-quota-axi-lib.sh` owns is REFUSED before anything is parsed, and the refusal names both the installed version and the floor.
Builds below the floor emit a different report layout entirely, so keeping a parser for it would mean this repository declaring a build unsupported and then reading it anyway - and a reading that looks fine from a build we reject is the precise failure this surface exists to prevent.
The refusal is deliberately louder than an ordinary `unknown`, and the summary still carries `build=below-floor(<min>)` so the label and the verdict agree rather than sitting side by side saying different things.
`bin/fm-bootstrap.sh` remains the owner of the operator-facing MISSING diagnostic for that build.
A build whose version could not be read at all is labelled `build=unknown` rather than `build=below-floor`, because the floor comparator treats an unreadable version as incompatible and printing that as a fact would be a definite claim about something never measured.

The whole reading is bounded by one cumulative budget shared across both `quota-axi` calls, and each caller bounds the command below the bound it is working within, as [`bin/fm-timeout-lib.sh`](../bin/fm-timeout-lib.sh)'s `fm_inner_bound` defines including its floor.
A bound granted per call, under a caller bounding the total, is a false-unmeasurable generator: the caller's kill lands first, and a gauge that was about to answer gets reported as one that could not be read.

## Why the record is generated, not saved

The instinct after an incident like this is to write the plan down before the wall.
That is the wrong lesson, and it is the one that nearly failed: a hand-written plan is stale the moment anything moves, is lost with the session that wrote it, and exists at all only if someone remembered to write it.

Nothing the record needs dies with the agents.
Task metadata, worktrees, branches, merge posture, delivered instructions, and open captain calls are all on disk and all survive the wall untouched.
So `resume` regenerates the record from that state on demand, which is not merely as good as a pre-wall snapshot but strictly better: it cannot be stale, and it is available to a session that never saw the wall coming.

It composes rather than re-parses.
[`bin/fm-fleet-snapshot.sh`](../bin/fm-fleet-snapshot.sh) is the declared owner of structured fleet state and supplies identity, merge posture, current state, endpoint, pull request, and open captain calls.
The record adds only what that snapshot does not carry and a recovery needs: the branch, head, uncommitted and unpushed counts, the attributed pipeline run and its branch custody, and the steering records the worker has and has not acknowledged.
It is published whole or not at all, because a half-written record read during a recovery is worse than the previous complete one.

The record carries state and points at the skill for procedure.
That split is what keeps the two from drifting.

## Why attribution binds on branch and reports the head separately

The stranded shape is specific: `branch_sync.state` reads `pipeline_owned` and the run head is ahead of, or entirely absent from, the task's local copy, because the pipeline commits its fixes in its own gate copy.

[`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh) owns the shared rule for binding a run to a worktree, and that rule requires the run head to be resolvable locally - which, in exactly this case, it is not.
Discarding the run there would hide the state a recovery most needs.

So `resume` and `diagnose` attribute on the run's branch and report the head relationship as evidence beside it: `equal`, `pipeline-ahead`, `pipeline-only`, `diverged`, or `unknown`.

Every one of those readings is gated on git being able to read the local copy at all, in one place rather than per fact.
A directory that exists is not the same fact as a repository that can be read, and the difference is silent in both directions: `git status --porcelain` prints nothing for a copy git cannot read, and the count of nothing is `0`.
Ungated, a worktree whose directory survived but whose git metadata is gone - pruned or relocated, exactly the half-state a post-wall recovery walks into - reported `branch: (detached) head: - uncommitted: 0`, two definite claims about a repository nobody could read.
The head relationship takes the same gate as a precondition, because its lookup fails identically for a copy missing the commit and a copy git cannot read, and `pipeline-only` asserts the first.
The record now says the copy could not be read, and reports nothing about its contents as measured.
They read the bare `no-mistakes axi` overview rather than `axi status`, because the overview is scoped to the invoking worktree's own run while `axi status` reports the repository's active-or-most-recent run - routinely another task's, on a repository with several worktrees validating at once.
This surface reports rather than acts, so naming the run and the relationship is the honest answer; acting on custody stays with the worker that owns the branch, under `AGENTS.md` section 7.

## Why the trigger is in the digest and not in anyone's memory

Knowledge that fires only when recalled is the failure being corrected, so the routing is printed on the observable condition rather than waited for.

- Before the wall, the session-start digest prints the gauge at the top of its live-fleet section, and `bin/fm-fleet-view.sh` prints it in the heartbeat review. Those are the two places a dispatch decision is actually made.
- At the wall, any endpoint the digest cannot read as alive gets the cheap endpoint-only scan - a dead one and one with no window recorded alike, both drawing on the same shared budget - and its verdict is printed beside the endpoint line with one shared pointer to the full diagnose and the skill.
- Mid-session, a dead or stale worker already routes through `stuck-crewmate-recovery` by an always-loaded contract, and that playbook's first step is now to rule out the wall.

A cheap scan that finds nothing reports `unknown`, never `no-signature`.
The 2026-08-23 evidence was in the step logs and not in the terminal, so a terminal-only negative is not a clean bill of health and must not read as one.

The same rule governs evidence that could not be read at all.
`no-signature` means the evidence was read and nothing matched, so a step log that failed to read reports `unknown reason=step-log-unreadable` instead, and a step nothing looked at is never listed as checked.
A step the scan budget never reached is a third fact again, disclosed as `unscanned=` rather than as `unread=`, because a read nothing attempted is not a read that failed.

`unread=` names evidence that was attempted and yielded nothing, and the terminal capture belongs to that list as much as a step log does: it appears there as the token `endpoint`, the same token `checked=` uses when the capture succeeded, with the concrete reason trailing the verdict.
A wedged terminal costs the whole capture bound and then contributes nothing, so a verdict naming only the step logs it did read would look cleaner than the evidence behind it.
A task with no endpoint recorded at all is not an unread endpoint and never carries the token, because nothing was attempted and there is no gap for a reader to close; its absence is stated as a trailing reason instead.

## Why a wall verdict needs corroboration

This detector reads a terminal capture and a pipeline step log, and both can contain this repository's own documentation of the detector.
The recovery skill and the verification record quote the vendor's limit phrasings verbatim, because a record that paraphrased its evidence would stop being a record.
The digest runs `diagnose --endpoint-only` automatically for every endpoint it cannot read as alive, so a crewmate who merely had this surface's skill or diff on screen when their endpoint died would otherwise be told `wall source=endpoint`, and told that the work is intact, about a task that genuinely failed.

That is a defect class rather than a detail of this one command: a mechanism whose evidence source includes its own documentation.
It will recur in anything that greps for text this repository also discusses, so it is worth recognising by name before writing the next such detector.

The two error directions are not symmetric, and that is what decides the fix.
A missed wall is self-correcting, because whoever is reading carries on and finds the real cause.
A false wall asserts the work is intact and stops the reading, so a confident wrong verdict is strictly worse than an honest unknown.

Only the positive is therefore tightened.
A `wall` verdict needs the vendor phrasing and the harness's own non-zero exit in the same evidence, on a different line, and the corroborating line must not itself carry a limit phrasing.
That last clause is what separates the harness's two emitted lines from one sentence of prose narrating both facts at once.
It costs no true positive on record: every real detection carries the harness's exit on its own line right after the limit line.
The negative stays `no-signature`, which is still not proof that the work crashed.

The rule is whole-evidence rather than proximity or window based, because a narrowed window would trade a real detection for an accident of layout.
The residual it leaves open is stated rather than hidden.
The residual is larger than one page, and it was understated here twice before it was measured properly.
Three tracked files still read as a wall: `docs/verification/usage-limits.md`, which quotes a real step log verbatim; `bin/fm-usage-wall.sh` itself, whose header quotes a limit phrasing while a later line carries an independent exit phrase; and `tests/fm-usage-wall.test.sh`, whose fixtures build the vendor lines from the same real text.
The detector's own source tripping the detector is the sharpest form of the defect class named above, and it is why the scope belongs here in measured terms rather than as an example.

How that number is established matters as much as the number, because the first answer here was wrong by sampling.
A 200-line window reads as a wall exactly when some limit line and some exit line that does not itself carry a limit phrasing lie within 199 lines of each other, which is decidable per file from the two line-number sets without sliding a window at all.
An earlier count slid a window in fifty-line steps, never landed on the offsets that trip the third file, and reported two - a number produced by a method that could not have found the third.
Closing it would mean either degrading a record whose value depends on quoting real evidence, or guessing from layout, and both are worse trades than the residual.

Revisit this if the vendor emits the phrasing and the exit on one line, if a real transcript turns up a multi-line wall being missed, or if a fourth tracked file starts reading as a wall.
The open question behind it, which a fourth round of widening this disclosure will not answer, is whether a wall verdict should be authoritative only where a structural signal exists - the harness's own non-zero exit together with the vendor's final line in a pipeline step log - and be demoted to a non-asserting hint on the pane path, where only a screen scrape is available and this repository's own text can be on screen.

## Why every bounded scan discloses what it skipped

Both scans are bounded, and both are cheapest when nothing is wrong.
That is the trap: a usage limit strands every worker on one account at once, so the state a scan costs most in is precisely the state it was built for, and an unbounded scan degrades exactly when it is needed.

So the cost of each is a constant rather than a function of how much is broken.
The digest's per-task scans share one budget across the whole fleet-state section instead of paying a bound per dead endpoint, and `diagnose`'s step-log scan shares one budget across the run's failed steps instead of paying a bound per step.
`bin/fm-fleet-view.sh` bounds its gauge read for the same reason, because the heartbeat review must cost a constant too.

A budget that runs out never buys silence.
Whatever it could not reach is named as unscanned - `scan-budget-exhausted` in the digest, `unscanned=` on a `diagnose` verdict, separate from the `unread=` list of evidence that was attempted and yielded nothing - so a partial scan can never be read as a clean one.
That is the same rule the gauge follows: unmeasured is unknown, never fine.

The step-log scan is deliberately uncapped by count.
It previously stopped after the first three failed steps, which silently decided in advance which evidence counted: a run whose fourth failed step carried the vendor limit line would have returned `no-signature`, the verdict defined as read-and-nothing-matched.
Bounding by time bounds cost without ever deciding that some evidence does not matter.

## Verification

[`docs/verification/usage-limits.md`](verification/usage-limits.md) records the dated empirical evidence: both gauge states against a real `quota-axi`, a record generated from real fleet state, and the endpoint-gone recovery proven end to end on a disposable task.
