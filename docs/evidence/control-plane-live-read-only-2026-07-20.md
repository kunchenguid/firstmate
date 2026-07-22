# Control-plane live read-only evidence

This evidence was captured at `2026-07-20T08:20:15Z` from an explicit, task-local source registry.
The registry enabled metadata-only Firstmate observation and did not query, steer, stop, restart, or mutate any live project or agent endpoint.
Transcript message bodies, command output, credentials, personal content, and project file contents were not retained.

## Registered-source reconciliation

The command emitted schema `fm-control-plane.v1` and reported every one of the 11 registered software sources as available.
The inventory contained four registered git projects, 18 observable worktrees, one Firstmate task, and eight native agent sessions within the declared discovery window.
Five worktrees and four native sessions had explicit custody registrations.
The remaining observable worktrees and sessions stayed visible as registration violations instead of being silently omitted.

The one Firstmate task had a present task worktree.
Its runtime state was `unknown` from source `observation-disabled`, proving the read-only run did not treat an unqueried Herdr endpoint, an open pane, or a historical status line as current work evidence.

The invariant checker reported 30 source-backed violations across these classes:

- `TRANSCRIPT_NEWER_THAN_HANDOFF`
- `TRANSCRIPT_NEWER_THAN_POSITION`
- `UNREGISTERED_SESSION`
- `UNREGISTERED_WORKTREE`
- `WORK_ITEM_FRESHNESS_MISSING`
- `WORK_ITEM_NEXT_ACTION_MISSING`
- `WORK_ITEM_PROOF_REQUIREMENT_MISSING`

Mail, documents, calendar, and business-outcome connectors remained explicitly `unregistered` in separate communications, documents, calendar, and finance trust domains.
No production, real-user, or revenue claim was made.

## Reproduction command

```sh
FM_HOME=/path/to/firstmate-home \
  FM_ROOT_OVERRIDE="$PWD" \
  bin/fm-control-plane.sh \
  --sources /path/to/private/control-plane-live-sources.json \
  --json
```

The private registry used exact local pointers and is intentionally not committed.

## Isolated Herdr lifecycle evidence

The lifecycle check used only the brief-mandated `fm-herdr-lab.sh` helper with a generated named non-default session.
The helper provisioned the session, created and listed one task-labeled workspace and pane, ran the control-plane fingerprint command while the lab existed, and tore the lab down through its EXIT trap.
The helper's default-session fleet-state tripwire passed, and the process exited successfully.
No Herdr call relied on ambient `HERDR_SESSION`, and no direct session or server lifecycle command was used.
