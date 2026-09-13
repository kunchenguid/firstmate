# AutoDev convergence

How proven AutoDev and Paperclip behavior moves into the FirstMate fleet without keeping two orchestration authorities.

## Rule

Removing AutoDev means moving its durable invariants first, not deleting its code first.
AutoDev and Paperclip stay available as a reversible migration backstop until semantic equivalence is proven.
No component below is retired by this change.

## Classification

Root-goal ownership stays a keep-as-invariant and already lives in the FirstMate path.
The system never treats worker completion as outcome truth: crew status files are wake events rather than current state, landing has its own library in `bin/fm-landed-lib.sh`, and fleet status deliberately has no completion state.
Continuation stays a keep-as-invariant and already lives in the watcher, the wake queue, and the inactive-outcome scan in `bin/fm-inactive-reconcile.sh`.
Acceptance stays a keep-as-invariant and already lives in the mode-specific Definition-of-Done contract in `bin/fm-dod-lib.sh`, rendered identically into ship briefs and promoted scout instructions.
Verification stays a keep-as-invariant: merge outcomes publish only on validated provider results in `bin/fm-merge-outcome-lib.sh`, and run attribution outranks pane prose in `bin/fm-nm-run-lib.sh`.
Independent review stays a keep-as-invariant: reviewers support the implementation owner and never replace it, implementers never self-approve, and cross-shard ownership stays explicit in the fleet registry.
Failure recovery stays a keep-as-invariant: dead sessions, failed subprocesses, and provider waits surface through liveness guards and bounded rechecks rather than silent abandonment.
Durable continuation state stays a keep-as-invariant: backlog records, task metadata, status logs, and merge receipts let a replacement coordinator reconstruct goal, progress, evidence, failures, and safe resumption.
Bounded authority stays a keep-as-invariant: locks are per-home in `bin/fm-lock.sh`, the fleet lease extends one-authority-per-home to manager processes, and registry writes validate before mutating.
No concurrent writers stays a keep-as-invariant: nested and overlapping homes fail validation in both secondmate seeding and fleet registration.

## Move into FirstMate

Cross-shard dependency records move into the fleet registry through `fm-fleet.sh dep add | list | done`.
Manager ownership routing moves into `fm-fleet.sh route` with deterministic SecondMate, project, and domain mappings.
Manager health moves into `fm-fleet.sh status` with running, model-wait, idle, blocked, stalled, stopped, and dead states.

## Reuse as library or primitive

Deterministic runners, verifiers, and lifecycle components from AutoDev may back shard internals where they strengthen an existing guarantee.
Any such reuse names the old responsibility, the new owner, the equivalent-or-stronger guarantee, the migration evidence, and the safe removal path before the old path is touched.

## Temporary backstop

AutoDev reasoning and Paperclip coordination remain runnable until the fleet demonstrates equivalent closure, review, and recovery behavior on real work.
Fleet control must never become an AutoDev wrapper around every FirstMate call.

## Retire

Nothing is retired here.
Each retirement candidate later needs its old responsibility, new owner, guarantee comparison, migration evidence, and removal path in the change that proposes it.
