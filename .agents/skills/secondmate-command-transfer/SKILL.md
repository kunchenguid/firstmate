---
name: secondmate-command-transfer
description: >-
  Agent-only procedure for moving a persistent secondmate between firstmate command and captain command, in both directions.
  Load before taking a lane under the captain's direct command or handing one back, when the captain asks to talk to a lane himself, before entering away mode with any lane under captain command, and whenever a lane's recorded command state is divergent or unrecognized.
user-invocable: false
metadata:
  internal: true
---

# Secondmate command transfer

`AGENTS.md` hard rule 4 is the default and stays the default: workers do not address the captain, and everything flows through firstmate.
This skill owns its one exception - a persistent secondmate the captain has deliberately taken under his own command - and the procedure that makes the exception safe in both directions.

The failure this exists to prevent is a lane with two commanders or none: the captain talking to a lane that is still routing everything through firstmate, or firstmate steering and answering for a lane the captain is driving himself.

## What is recorded, and where

One owner: the optional trailing `command:` field on the lane's line in this home's `data/secondmates.md`.
`firstmate` (or an absent field) is ordinary command; `captain` is the transferred state.
`bin/fm-secondmate-command-lib.sh` owns the read contract and `docs/configuration.md` points at the field.

The seeded home's `data/command.md` is a derived copy the lane reads to know which state it is in.
The registry always wins.
A disagreement between them is a stop-and-report result: `bin/fm-secondmate-command.sh status` exits non-zero and names it, and firstmate repairs it before acting on that lane at all.

Nothing else records command state.
`state/` is not the owner: it is the volatile tier, and `state/<id>.meta` is rewritten by every relaunch, so a recovery respawn would silently pull a lane back under firstmate command with nobody deciding it.

## The transfer is firstmate's to perform, not a command the captain runs

This skill is deliberately agent-only.
The captain says "I want to take sm-X for a while" in his own words; firstmate performs the transfer and answers in outcome language.
Two reasons, both about safety rather than tidiness:

- The transfer is only safe after a reconciliation only firstmate can do - checking for questions still addressed to it, requests still owed an answer, and a validation run whose decision authority would split mid-flight. A command the captain typed himself would either refuse in vocabulary section 9 forbids putting in front of him, or hand him an unreconciled lane.
- Firstmate is the party that has to *stop*. A transfer performed around firstmate leaves its live supervision cycle running on the old assumption until the next session start. Making firstmate perform it changes its own supervision in the same breath.

`bin/fm-secondmate-command.sh` still exists as a plain script, so the captain is never locked out; it is simply not the documented path.

## Onramp: firstmate command to captain command

1. Confirm which lane, in the captain's own words, and say plainly what he will and will not own while he holds it.
2. Run `bin/fm-secondmate-command.sh onramp <id>`.
3. The script refuses, with no override flag, on any of the seven unsafe states its header defines - the lane is unregistered, its home does not validate, away mode is active, its endpoint is confirmed absent, a decision it opened is still unresolved, a request from firstmate is still owed an answer, or a task in its home is inside a live validation run.
   Every one of those is a stop-and-report: clear the named condition first, or tell the captain why the lane cannot be handed over yet.
   Never work around a refusal by editing the registry or the home marker by hand.
4. On success the script writes the lane's position record under `data/<id>/`, flips the registry, writes the lane's own copy of its command state, and sends the running agent a notice to re-read it now.
   Read that record and relay its substance to the captain in plain language: what the lane is in the middle of, what is queued, and anything he is inheriting mid-flight.
   `TRANSFERRED_NOT_NOTIFIED` (exit 5) means the transfer is on the record but that notice was not delivered, so the running agent still believes firstmate commands it until it re-reads its own copy.
   The transfer is real either way - the record is the authority - but tell the captain his pane is not live yet, and deliver the notice or restart the lane before he relies on it.
5. Tell the captain, in one message: the lane is his, where to talk to it, and that firstmate will not steer it, route work into it, or retire it until he hands it back.

Then stop supervising that lane's work.
Firstmate keeps watching its **life**, not its work: the session-start liveness sweep still relaunches a confirmed-dead lane, because a dead pane gives the captain nothing and relaunching is infrastructure rather than command.
That relaunch is never silent - it always reports, because the captain's conversation in that pane did not survive it, and he needs to be told his lane restarted and lost the thread.

## While the captain holds a lane

- Firstmate does not steer it. `bin/fm-send.sh` refuses; the only messages that still reach it are infrastructure - the handback request this skill issues, its retry, and the re-read notices that tell the lane about its own files.
- Firstmate does not route work into it. `bin/fm-backlog-handoff.sh` refuses.
  In-scope work that arrives while the captain holds the lane stays in the main backlog as its own item, held with `tasks-axi hold <id> --reason "<reason>" --kind captain` naming the lane, and is re-evaluated at handback.
  That is the honest answer: the work is not silently misrouted into a queue nobody is reading, and it is not silently dropped either.
- Firstmate does not retire it. `bin/fm-teardown.sh` refuses, with or without force.
- The always-on watcher absorbs the lane's status events instead of waking firstmate, and never ages its idle pane toward a wedge.
- The away-mode daemon keeps putting the lane's captain-relevant events into the captain's digest - he is away and reading only the digest - but labels them as his own lane so the digest never presents them as firstmate work, and never calls the lane a wedge.

If a captain-commanded lane wedges - it stops responding and the captain says so - treat it exactly as a stuck direct report for the *infrastructure* part only: inspect the endpoint, relaunch if it is confirmed dead, and report. Do not steer it back into work.

## Away mode

The onramp refuses while away mode is active: a lane cannot be handed to a captain who is not present.

The reverse - the captain walks away with a lane still under his command - is allowed but must be deliberate.
Before entering away mode, run `bin/fm-secondmate-command.sh status`.
If any lane is under captain command, tell the captain before he goes and ask whether to hand it back; if he leaves it with him, it stays his, idle, with its events reaching him only through the away digest.
Away mode never authorizes taking a lane back on firstmate's own judgment.

## Offramp: captain command to firstmate command

Not the mirror image.
Coming back, firstmate has a gap: everything the captain and the lane did while firstmate was not watching.
The offramp closes that gap explicitly, and refuses to resume supervision on assumptions.

1. `bin/fm-secondmate-command.sh offramp-request <id>` records the exact report path it expects and asks the lane for its own position report.
2. Wait for the lane to write it. The lane reports what changed under captain command, what is under way, what is unresolved, and anything firstmate must know.
3. **Read the report.** This step is the point of the whole offramp; a completed handback with an unread report is the main way this feature could cause harm.
4. Reconcile it against durable records before resuming supervision:
   - the lane's own backlog and `state/<id>.meta` records in its home, against what the report claims,
   - the position record written at the onramp, so you can see what actually moved,
   - the main backlog's held items for that lane, which now become dispatchable again,
   - any PR, branch, or landed work the report names, checked rather than taken on trust.
   Where the report and the records disagree, the records are evidence and the disagreement is worth raising with the captain, not smoothing over.
5. `bin/fm-secondmate-command.sh offramp-complete <id> --report <path>` returns the lane.
   It refuses unless that exact report exists and postdates the request, so a stale or substituted document cannot stand in for one.
   On success it writes the lane's own copy of its command state and sends the running agent a notice to re-read it now.
   `TRANSFERRED_NOT_NOTIFIED` (exit 5) means the lane is firstmate's again on the record but that notice was not delivered, so the running agent still believes the captain reads its pane; deliver the notice or restart the lane before steering it.
6. Resume ordinary supervision, and clear the captain-kind holds on work that was waiting for the lane.

If the lane is dead and cannot report, that is a stop-and-report: relaunch it and re-request.
There is no path that completes a handback without the lane's own fresh report.

## Reporting to the captain

Section 9 applies unchanged.
Say "the lane is under your command", "I've stopped steering it", "here is what it was in the middle of", "it has reported back and I've picked it up again".
Do not put registry fields, marker files, exit codes, or refusal identifiers in front of him; name the concrete blocker instead ("it is mid-review on a change and the decision would change hands halfway - let it finish first").
