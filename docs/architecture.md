# Architecture

Firstmate is a local coordination layer for Ross' project work.

It preserves a narrow boundary: the primary reads project clones and manages fleet state, while crewmates change projects in isolated worktrees.

tmux is the only supported runtime backend.

## Local fleet

One primary Firstmate home owns the local task queue, task briefs, watcher state, and local project registry.

Crewmates run in tmux windows with a recorded task id and isolated worktree.

The primary treats task status lines as events and asks `fm-crew-state.sh` for current state when a decision depends on it.

The primary never writes a project except under an explicit, concrete captain-approved operation.

## Local secondmates

A local secondmate is a persistent isolated Firstmate home with a charter and a local tmux endpoint.

The primary routes only explicitly assigned work into that home.

A secondmate reconciles its own existing work after restart, then idles until further work arrives.

`data/secondmates.md` and the provisioning skill own the registry and lifecycle contract.

## Event-driven supervision

The local watcher observes durable task state and appends actionable records to `state/.wake-queue`.

The primary drains that queue before acting on a wake and acknowledges records only after handling them.

This makes a restart non-event because queued work remains durable until its exact acknowledgement is recorded.

One healthy supervision cycle is required whenever work is under way.

Harness-specific wait mechanics are emitted at session start, while `fm-watch-arm.sh` owns watcher arming.

## Process-to-event sources

Process-to-event sources turn a registered external or local condition into captured durable state.

The source runner owns capture and acknowledgement storage, while the source adapter owns its result semantics.

The captured result is retained separately from the wake line so the wake queue stays bounded and replay-safe.

The `process-event-sources` skill owns source handling and retirement rules.

## Worktrees and task lifecycle

Ship tasks and scout tasks always start from an isolated worktree.

A ship task changes a project only through an explicitly authorized delivery path.

A scout task produces a report at `data/<id>/report.md` and does not authorize implementation by itself.

Before a task can be torn down, the lifecycle verifies the appropriate landed-work or scout-report condition and preserves unlanded work.

Sensitive actions require explicit captain direction, including spawning, pushing, opening or merging pull requests, applying a local change to a primary checkout, discarding work, using credentials, and spending money.

Validation evidence can recommend an action but cannot authorize it.

## Busy state and delivery

Current task state is semantic rather than inferred from one rendered terminal string.

`fm-busy-lib.sh` owns task busy-state vocabulary, and the tmux adapter contributes verified pane and process signals.

`fm-send.sh` sends only through the recorded endpoint and fails closed when delivery cannot be confirmed.

`fm-control.sh` owns explicit task lifecycle actions such as interrupt, exit, and relaunch.

## Private state and recovery

Private state lives below the active `FM_HOME`.

`data/` holds durable records, `state/` holds runtime and wake records, `config/` holds local settings, and `projects/` holds clones.

The session-start digest acquires the per-home lock, presents wakes, and reports fleet state before normal work resumes.

Recovery reconciles only the recorded direct reports in that home, preserving their worktrees and unlanded changes.

## Documentation ownership

[configuration.md](configuration.md) owns local state formats and configuration.

[tmux-backend.md](tmux-backend.md) owns tmux setup and runtime behavior.

Script headers own exact flags and mutation mechanics.

The documentation audience inventory in [documentation-audiences.md](documentation-audiences.md) defines the maintained prose boundary.
