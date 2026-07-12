# Codex Persistent Supervision Design

## Problem

Normal Codex supervision currently uses bounded foreground checkpoints.
A checkpoint owns `fm-watch.sh` only while its tool call is running.
When that call returns, no watcher process remains.
A later crewmate status write can touch its turn-end marker or status log, but it cannot reopen a completed Codex turn.
The wake is discovered only when a captain message or the primary Stop hook causes another checkpoint.

Live evidence on 2026-07-11 showed a crewmate turn-end marker and status update with no `.watch.lock`, no `.supervise-daemon.pid`, no `.supervision-owner`, and an empty durable wake queue.
This proves the missed notification is an ownership gap, not a status-classification failure.

## Goal

Keep exactly one persistent watcher owner for a normal Codex primary and deliver captain-relevant crew events into an idle Codex session without captain polling.

## Architecture

Normal Codex reuses the existing singleton supervisor daemon that already backs away mode.
The daemon owns and re-arms `fm-watch.sh`, classifies wakes, retains undelivered escalations, and submits one sentinel-prefixed digest only when the primary agent is idle and its composer is confirmed empty.

A durable `state/.supervision-owner` file has a closed value set of `normal-codex` or `afk`.
Normal and away modes transfer ownership of the same live daemon instead of stopping one watcher and starting another.
An absent, unreadable, unexpected, or marker-inconsistent owner fails closed and preserves queued escalation evidence.

`bin/fm-codex-supervise-start.sh` is the normal-mode entry point.
It adopts an identity-verified live daemon or starts the singleton in a tracked terminal session.
The foreground checkpoint remains available only for diagnosis and recovery.

## Startup Transaction

The launcher must never leave `normal-codex` ownership recorded unless a live daemon owns the singleton lock and has validated the supervisor backend and target.
For adoption, the launcher verifies the existing daemon identity before transferring ownership.
For a new daemon, the daemon records ownership only after acquiring its lock and validating the injection target.
Startup failure clears any ownership written by that attempt while preserving an owner established by another live daemon.

## Normal and Away-Mode Transfer

Entering AFK sets the away marker and transfers ownership to `afk` without restarting the daemon.
Returning from AFK under a Codex primary clears the away marker and transfers ownership back to `normal-codex` without restarting the daemon.
Non-Codex primaries retain the existing behavior of clearing ownership and stopping the away daemon.

## Delivery Safety

The daemon never injects while the primary is busy.
The daemon never injects into pending input, an unreadable pane, or a bare shell.
The daemon types a digest once and retries only Enter when submission is swallowed.
An unconfirmed submission remains buffered.
Watcher and daemon locks remain singleton, identity-backed, and scoped to the active Firstmate home.

## Operating Contract

Codex session-start instructions direct the primary to start or adopt the normal daemon in a tracked terminal session.
The Stop hook repair line names the same launcher when supervision is missing.
Normal Codex must not run a competing foreground checkpoint while the daemon owns supervision.

## Verification

Tests must reproduce the old gap, prove transactional startup failure leaves no false owner, prove singleton adoption, and prove normal-to-AFK-to-normal transfer keeps one daemon and watcher.
The existing daemon, queue, checkpoint, and instruction suites must remain green.

A real Herdr smoke is mandatory.
It starts the daemon against an idle disposable Codex pane, writes a captain-relevant status from a separate process, and proves the status opens a new Codex turn without a captain message, foreground checkpoint, or manual queue drain.
The smoke also proves the daemon PID and watcher beacon remain live after delivery.

## Delivery

The implementation stays on `fm/fix-codex-supervision-loop-d4` and rebases onto current `origin/main`.
It ships through Firstmate's normal validation and PR workflow.
No merge occurs without the captain's explicit instruction.
