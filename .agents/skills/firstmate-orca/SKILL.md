---
name: firstmate-orca
description: Agent-only operator checklist for Firstmate's Orca runtime backend. Use when recovering or supervising eligible legacy Orca-backed work, testing Orca backend behavior, debugging Orca task state, or reconciling Orca-backed task metadata.
user-invocable: false
metadata:
  internal: true
---

# firstmate-orca

Use this as the operator checklist for Firstmate's experimental Orca runtime backend.
It does not replace `AGENTS.md`, `docs/orca-backend.md`, or `harness-adapters`.

Orca is a runtime backend, not an agent harness.
The runtime backend owns the task endpoint and, for Orca, the task worktree.
The harness is the agent process launched inside that endpoint, such as `claude`, `codex`, `opencode`, `pi`, or `grok`.
Load `harness-adapters` for harness-specific launch, interrupt, resume, trust-dialog, and skill-invocation facts.

Implementation details, metadata fields, teardown guarantees, limitations, and smoke evidence live in `docs/orca-backend.md`.
Prefer the `bin/fm-*` helpers over raw `orca` commands.
Use raw `orca` only when the helper surface cannot answer the inspection question, and keep the recorded firstmate metadata as the task identity.

## Preflight

Work from the current firstmate home or repo root.
If `FM_HOME` is set, remember that operational state lives under `$FM_HOME` while the helper scripts still run from this repo's `bin/`.

Before inspecting an Orca-backed legacy task:

- Confirm the task meets the eligibility contract in `docs/orca-backend.md`; new work must use tmux, Herdr, zellij, or cmux.
- Inspect active `state/*.meta` records before changing backend selection.
- Do not set Orca as the durable backend for a home that launches new tasks.
- Reconcile watcher wakes before unrelated work, especially if Orca tasks are already in flight.
- Do not respawn or destructively tear down an Orca task while the adapter reports that lifecycle authority capabilities are unavailable.

## Spawn

New task spawns refuse `backend=orca` before any owned mutation.
Legacy respawn also fails closed until an empirically verified provider capability can bind terminal, task label, worktree, and repository identity and enumerate every terminal attached to a worktree.
`docs/orca-backend.md` owns the evidence and re-enablement contract.

Do not manually create the Orca worktree or terminal for an eligible firstmate recovery.
Do not manually patch metadata to make an externally-created Orca terminal look like a firstmate task.

## Supervision

Use `bin/fm-peek.sh`, `bin/fm-send.sh`, `bin/fm-crew-state.sh`, and `bin/fm-teardown.sh` for routine operation.
For steer messages, send short lines through `bin/fm-send.sh <id> '...'`; the stable `fm-<id>` alias also works.
Put long instructions in the task brief or a temporary file and point the crewmate at that file.

When supervising, treat `state/<id>.meta` as the routing record and Orca's own ids as backend implementation details.
The stable firstmate alias is `fm-<id>`.
The recorded `terminal=` and `orca_worktree_id=` fields are what backend helpers use under the hood.

If `fm-send` fails to submit, do not immediately repeat the same long instruction.
Peek first, then decide whether the target is busy, waiting on a prompt, stuck behind a popup, or genuinely wedged.
For harness-specific interrupts or exits, load `harness-adapters`.

## Recovery

For a messy Orca-backed task:

1. Read `state/<id>.meta` and the relevant status tail first.
2. Confirm the task is actually Orca-backed before using Orca-specific assumptions.
3. Use the recorded `terminal=`, `orca_worktree_id=`, and `worktree=` as the task identity.
4. Prefer firstmate helpers for peek, send, state, and teardown.
5. Avoid raw deletion of Orca worktrees or manual branch cleanup.
6. Stop and inspect if the recorded worktree path, Orca worktree id, or project checkout no longer matches expectations.

Teardown remains governed by `docs/orca-backend.md` and retains resources when lifecycle authority is unavailable.

## Regression Verification

Do not synthesize legacy metadata or spawn a disposable Orca task merely to smoke-test the backend.
Run the focused fake-Orca suite in `docs/orca-backend.md` to verify lifecycle plumbing.
Do not use an actual legacy recovery to assert lifecycle safety until the required authority capability has empirical evidence.

Do not mix adapter verification with unrelated feature work.
