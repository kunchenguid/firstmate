# Visual frontend contract

Status: planned, not implemented.

This document defines the visual frontend for firstmate.
It exists to answer one recurring confusion clearly: firstmate already has visible surfaces, but they are terminal-native session backends, not a dedicated web or desktop dashboard.
The visual frontend defined here is a captain-facing observer and control surface layered on top of the existing firstmate runtime.
It is not a new runtime backend, not a second orchestration system, and not a second truth source.

## Why there is no visual frontend today

Today, firstmate's visible operating surface is the backend itself: tmux windows, herdr tabs, zellij tabs, cmux workspaces, or Orca terminals.
That is the current product.
It is why the README says there is no app to install.

Codex App is also not the missing visual frontend.
`codex-app` is currently blocked as a shell-callable runtime backend, which is a different concern from rendering firstmate state in a visual surface.

## Product goal

The visual frontend should give the captain one place to:

- see fleet state at a glance
- inspect one task without reading raw state files
- review captain-owned decisions and approvals
- send bounded steering actions through existing firstmate commands
- open the underlying terminal surface when deep work or trust requires it

The frontend is successful when it reduces tab-juggling without weakening firstmate's existing safety boundaries.

## Non-goals

- It does not replace tmux, herdr, zellij, cmux, or Orca as task endpoints.
- It does not become a new runtime backend.
- It does not write directly into project repos.
- It does not invent a second task state model beside firstmate's existing disk and script contracts.
- It does not bypass `fm-spawn`, `fm-send`, `fm-crew-state`, `fm-peek`, `fm-pr-merge`, `fm-merge-local`, or teardown guards.
- It does not require Codex App backend support to exist first.

## Authority boundary

The frontend is a view and control layer over existing firstmate contracts.

Read authority:

- `bin/fm-fleet-snapshot.sh --json` is the primary read model for fleet overview.
- `bin/fm-crew-state.sh <id>` is the authority for a task's current state.
- `bin/fm-peek.sh <id>` is the bounded transcript and terminal preview surface.
- existing docs and task reports remain the authority for human-readable detail

Write and action authority:

- `bin/fm-send.sh`
- `bin/fm-spawn.sh`
- `bin/fm-wake-drain.sh`
- `bin/fm-pr-merge.sh`
- `bin/fm-merge-local.sh`
- `bin/fm-teardown.sh`

The frontend may shell these commands or call a thin local wrapper around them.
It must never reimplement their state transitions in frontend code.

## Required screens

### 1. Fleet overview

Purpose: one-screen captain summary.

Must show:

- active work
- captain-owned decisions
- blocked items
- recent landed work
- watcher and away-mode status
- backend type per live task

Primary source: `bin/fm-fleet-snapshot.sh --json`.

### 2. Task detail

Purpose: inspect one task end to end.

Must show:

- task identity and brief summary
- current state from `bin/fm-crew-state.sh`
- bounded recent status history
- bounded peek output from `bin/fm-peek.sh`
- linked PR or report when present
- exact backend target metadata when relevant

### 3. Captain queue

Purpose: separate "needs my decision now" from ordinary ongoing work.

Must show only captain-owned actions such as:

- merge approval
- local-only landing approval
- ask-user findings
- explicit decisions held through the decision-hold lifecycle

This surface should be a projection of existing lifecycle data, not a new inbox format.

### 4. Action rail

Purpose: allow safe, narrow control without opening the shell first.

Initial allowed actions:

- send a message to a task
- send `Enter`, `Escape`, or `Ctrl-C` where already supported
- wake drain
- open report or PR
- open the underlying backend target

Every action must show:

- exact command being invoked
- success or failure
- any changed durable state the command reported

### 5. Backend inspector

Purpose: make the terminal-native surface legible rather than hidden.

Must show:

- which backend owns the task
- target identity such as tmux window, herdr pane, zellij pane, Orca terminal, or cmux workspace/surface
- whether the backend is directly inspectable from the frontend or must be opened externally

## UX principles

- Read-only first.
- One screen should answer "what needs me now?" in under five seconds.
- The frontend should expose the underlying truth path, not hide it.
- Every destructive or approval-bearing action should keep firstmate's existing friction and wording.
- When state is unknown, the UI should say unknown, not guess.
- A task detail page should always offer a direct jump to the real terminal surface.

## Recommended implementation shape

The first implementation should be a local web app, not a runtime backend.

Recommended stack:

- React
- TypeScript
- Vite

Reasoning:

- Vite is enough for a local dashboard.
- It keeps the surface optional and decoupled from firstmate's bash runtime.
- It avoids turning the frontend into a server-heavy product before the control contract is proven.

The frontend should consume JSON from a thin local adapter layer that shells the authoritative `bin/` commands and returns normalized results.
That adapter is allowed to be small and boring.
It is not allowed to become a second orchestration engine.

## Rollout phases

### Phase 1. Read-only dashboard

Deliver:

- Fleet overview
- Task detail
- Captain queue

No mutating actions beyond open-in-terminal or open-PR/report links.

### Phase 2. Safe steering

Deliver:

- send text
- send supported keys
- wake drain

All actions route through existing scripts and echo exact results.

### Phase 3. Approval actions

Deliver:

- merge PR through `bin/fm-pr-merge.sh`
- land local-only work through `bin/fm-merge-local.sh`
- teardown through `bin/fm-teardown.sh`

Keep current approval authority unchanged.

### Phase 4. Rich backend affordances

Optional, backend-specific enhancements such as:

- deep links into terminal apps
- attached screenshot previews where capture is safe and explicit
- backend health diagnostics

These are optional because backend safety and focus behavior differ materially across tmux, herdr, Orca, cmux, and zellij.

## Relationship to Codex App

The visual frontend can exist before `codex-app` backend support.

If Codex Desktop later exposes a supported shell-callable bridge, that work should plug into the same frontend contract in two distinct ways:

- as one more backend that firstmate can supervise
- as one possible host surface for the visual frontend

Those are separate rollout decisions.
Neither one should be smuggled in as the other.
