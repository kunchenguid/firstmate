# Fleet board

The fleet board is Firstmate's always-on local browser application for seeing every current task as a Kanban card.
It keeps task status scannable without creating a second project-management system.

Run `/fleet` from the Firstmate conversation to start or reopen it.
From a shell, run `bin/fm-fleet-board.sh open` for the same result.
The application keeps running independently of the page until `bin/fm-fleet-board.sh stop` is called.

## What the board shows

The primary view has six status lanes.

1. **Backlog** contains queued work that is ready to start.
2. **In Progress** contains work an agent is actively executing.
3. **Verification** contains work whose current activity is tests, review, or another recorded validation step.
4. **Needs You** contains a current decision or blocker that requires the captain.
5. **Waiting** contains blocked, held, paused, failed, unavailable, or otherwise non-progressing work.
6. **Done** contains the recent completion baseline retained by the canonical backlog and registered secondmate summaries.

Cards do not support drag and drop.
A card's lane is a direct projection of current Firstmate state, so manual movement would make the interface less truthful.
The browser refreshes automatically and exposes a manual Refresh control when an immediate read is useful.

Each card shows the task title, home, risk, current status, concise context, and evidence count.
Opening a card reveals the risk rationale, repository, work type, status source, full projected context, and recorded pull request, report, activity, blocker, or link evidence.
Search and home or risk filters narrow the view without mutating it.

## Captain actions

Needs You cards expose **Answer Firstmate**.
Every open structured card exposes **Request more details**.
When one task has several open captain decisions, the card shows every key and the answer composer requires the captain to select the decision being answered.

Both actions create a durable instruction in Firstmate's existing inbox and attempt to wake the normal Firstmate session.
If the note is saved but its wake fails, the composer keeps the same request id and offers a safe wake retry.
The server does not release a hold, close a task, steer a worker, or change a lane directly.
The card remains in its canonical lane with a sent confirmation until Firstmate processes the instruction and the next snapshot observes the resulting state.

This routing is deliberate because Firstmate already owns task authority, remote secondmate routing, decision release, and lifecycle safety.

## Risk

Risk is not inferred from priority, title, repository, or presentation text.
Firstmate records an explicit low, medium, or high assessment with a short rationale when it files or materially rescopes a task.
The assessment considers blast radius, reversibility, uncertainty, and security, privacy, data, payment, production, compliance, or external-user impact.
Homes using the configured manual backlog backend preserve the same owned record during their normal manual task-body edit.

Legacy or not-yet-assessed tasks appear as **Unassessed**.
An invalid risk record also stays unknown rather than being guessed.
`bin/fm-task-risk.sh` owns the exact assessment record and update mechanics.

## Availability and safety

The application binds only to `127.0.0.1` and is not a remote collaboration server.
The browser loads only bundled assets and calls the same loopback origin, with no third-party scripts, fonts, or analytics; registered remote-secondmate reads still follow the existing [remote secondmate](remote-secondmates.md) path.
HTTP requests require a loopback Host, while state-changing requests also require a per-process action token and reject any supplied non-loopback Origin.
The Firstmate inbox owns durable action request ids, so retries after wake failures, process restarts, or later replays resolve to the same note instead of creating another instruction.
The default port is selected once per Firstmate home and then retained so browser-side in-flight recovery survives server restarts, while a home-scoped storage key prevents one home from restoring another home's operation on an explicitly shared port.

The board keeps a short in-memory snapshot cache so multiple browser requests do not fan out into duplicate fleet reads.
If a refresh fails after a successful read, it keeps the last good board visible and marks it stale with the failure reason.
Actions remain available on those stale cards because they only queue an instruction; submission revalidates against a forced current read or the visibly stale last-good card, and the instruction requires Firstmate to revalidate canonical task state before acting.
Registered-home bounds and omissions remain visible as warnings rather than silently hiding work.

Runtime identity and logs live under `state/fleet-board` in the selected Firstmate home.
The stop command signals a process only after its health endpoint proves the recorded instance identity.

## Operator commands

Run `bin/fm-fleet-board.sh status` to verify the application and print its URL.
Run `bin/fm-fleet-board.sh url` when only the verified URL is needed.
Run `bin/fm-fleet-board.sh stop` to stop the verified application.
Run `bin/fm-fleet-board.sh serve` only when a foreground process is required by a supervisor or a test.

`bin/fm-fleet-board.sh --help` owns the exact command and environment contract.
