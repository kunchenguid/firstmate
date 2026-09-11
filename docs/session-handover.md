# Session handover

This is the authoritative current contract for replacing a Firstmate session with a fresh one.
AGENTS.md section 8 carries the operating stub; the `handover` skill carries the procedure; each script's header and `--help` own exact flags and mechanics.

The problem it closes: when the captain replaces a session, everything the outgoing one knew that never reached disk is lost, and the replacement re-derives it or gets it wrong.

## Nothing here measures a session

There is no threshold, no token count, no silence timer, and no turn-end hook behind this.
A handover starts when the captain asks for one, and until then this machinery does nothing at all.

That is a deliberate limit rather than an omission.
Measuring "is this session still reasoning well?" means reading the transcript on every turn end of every session, and the only honest answer that produces is a number with no agreed meaning.
Judging when a session has gone on too long is the captain's call, and this contract starts where that call is already made.

## The handover is captain-triggered

A watcher cannot respawn the interactive session in the captain's terminal, so nothing here replaces a session by itself.
Firstmate prepares, verifies, and reports; the captain starts the replacement.

## The record points, it does not assert

`data/handover.md` is durable, never a temp file, and the previous record is kept as `data/handover-prev.md`.

It is explicitly advisory: the durable records win every disagreement with it.
A session old enough to be replaced is exactly the session whose recollections should not be trusted, so the only content it asserts is the content that exists nowhere else - the concrete next step, and what each live worker is mid-way through.
Everything else is a pointer the replacement can check.
Live fleet state is deliberately absent, because `bin/fm-session-start.sh` prints it fresh.

A released record prints in full in the session-start digest, under the read-once contract: the replacement reads it there and never opens the file again.

## The refusal

`bin/fm-handover.sh release` verifies before it frees anything, and refuses with the exact missing item.
Once the outgoing session is gone a bad handover cannot be redone, so this refusal is the most important behavior in the feature.

It requires all of:

- a present, non-empty record carrying a `Next step:` line;
- a note for every live worker in `state/*.meta`, saying what it is mid-way through;
- a durable record behind every live thread - a backlog item for a task, a registry entry for a direct report;
- every pointer in the record resolving to a file that still exists and is non-empty.

`prepare` applies the worker half of that list too, so an unaccounted worker fails early rather than at release time.
Everything is re-checked at release even when `prepare` just passed, because a task can appear, and a record can be edited or truncated, in between.

Nothing here discards anything: it never stops a session, never touches unlanded work, and never drains the durable wake queue.

`prepare`, `release`, and `consume` all require this session to hold the helm.
A session refused the lock still reads the record and is shown it in full at session start, but it may not rotate it away or mark it picked up: a `prepare` from a session with no authority would replace the outgoing holder's record with one it composed, and a `consume` from one would leave the session that actually takes the helm told nothing is waiting.
Information is never withheld from a refused session; only its ability to mutate is.

## The gap

Monitoring stops when the outgoing session ends and resumes when the replacement arms it.
That gap is accepted and made visible rather than hidden: queued wakes survive it on disk, `release` reports how many are waiting, and the replacement drains them at session start.

## The helm is never taken

A fresh session never takes the helm from a live holder, and nothing here decides that a holder is idle enough to displace.
Deciding that requires proving a session is not working, which needs the same transcript measurement this contract deliberately does not carry - and an over-estimate of silence is exactly the error that permits a wrongful takeover.

So `bin/fm-lock.sh` refuses, and the refusal has to be actionable on its own: it names the pid that holds the helm and prints `bin/fm-lock.sh clear --pid <holder>`, the one command that clears the record.
`bin/fm-lock.sh status` prints the same command beside a live holder.

`clear` refuses any pid that is not the recorded holder, so a stale reading of `status` cannot clear a helm that has since changed hands.
It drops the recorded helm only, never claims to have stopped anything, and says so: the other session is still running and has to be quit too, or two sessions work the same fleet.
`bin/fm-lock.sh release` gives up the helm only for the session that holds it.

The accepted cost is that a holder nobody is using keeps the helm until a person clears it by hand.
That is the safe direction: handing the helm away from a session someone is still using is worse than one refusal the captain has to act on.

## Not covered here

- Any automatic trigger for a handover, whether by token count, silence, or elapsed time.
- Automatic respawn of crewmates at a context ceiling. The handover machinery is deliberately shared, but nothing drives it for a worker.
- Cross-provider handoff when a provider's quota is exhausted. Quota is reported per provider, not per agent, so respawning on an exhausted provider yields an equally stuck worker; that is a separate concern.
- A wedged agent that never ends a turn. `stuck-crewmate-recovery` owns those.

## Verification

The behavior tests are `tests/fm-session-handover.test.sh` and the handover case in `tests/fm-session-start.test.sh`.
