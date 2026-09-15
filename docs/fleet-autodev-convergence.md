# AutoDev convergence

AutoDev and Paperclip remain runnable migration backstops while the FirstMate fleet proves equivalent execution and closure behavior.
This change retires neither system.

## Ownership Split

Harness remains the persistent SecondMate for the `AutoDev` and `dotcodex` projects.
Fleet schema version 2 registers that semantic fact independently of whichever physical manager currently supervises Harness.
The normal intake route is `AutoDev -> harness -> current manager`.
Changing the current manager does not change the project owner, clone list, backlog, or completion evidence.

## Preserved Invariants

Root-goal ownership stays with the existing FirstMate lifecycle.
Crewmate completion does not complete a SecondMate or root outcome.
The Definition of Done, landing evidence, validated provider results, independent review, watcher continuation, and inactive-outcome reconciliation remain their existing owners.
Fleet assignment state cannot express done, reviewed, landed, accepted, or complete.

The manager registry adds bounded operational supervision only.
Its dependencies name SecondMates, its health reports do not claim outcome status, and its transfer journal cannot replace a lifecycle receipt.

## Harness Pilot

Before the Harness move, preserve its source `data/secondmates.md` row, parent metadata, parent status channel, `.fm-secondmate-parent` binding, and current assignment generation in the fleet transaction journal.
Stop the original FirstMate supervision session and selected destination manager before rewriting owner records.
An open, escalated, or recovery-unknown pending reply blocks the transfer.

After publication, the selected manager is the only parent route for the relaunched Harness endpoint.
The endpoint is restarted so no launch-time environment names the former parent.
A later controlled recovery chooses the least-loaded healthy reasoning manager without asking the operator to select physical capacity.

Use `transfer recover` after a crash between owner-record movement, assignment publication, and endpoint relaunch.
Use `transfer rollback` only while both relevant manager homes are stopped and the published generation still matches the journal.
Resolved pending-reply records remain in the source home across either path.

## Retirement Gate

Retirement requires real work to prove intake routing, manager loss recovery, Definition-of-Done enforcement, independent review, landing, and consumer-visible closure.
Local tests and a successful assignment transfer are necessary evidence but do not retire AutoDev or Paperclip.
