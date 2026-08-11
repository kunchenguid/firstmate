---
name: validation-supersession
description: >-
  Agent-only procedure for replacing work after a current explicit captain instruction completely invalidates an active no-mistakes validation run.
  Load before aborting that run, recovering branch custody, replacing obsolete work, or starting the one authoritative replacement validation.
user-invocable: false
metadata:
  internal: true
---

# Validation supersession

Use this procedure only when a current, explicit captain instruction completely invalidates work already under active no-mistakes validation.
Lesser changes go to follow-up work under the task lifecycle in `AGENTS.md` section 7.
The same worker retains the task for a qualifying supersession.

## Procedure

1. Cancel the active run through no-mistakes axi's supported abort command.
2. Confirm through structured axi status that the run has stopped before changing any code.
3. Follow `branch_sync.next_action` from that status.
4. Use axi sync's supported guarded recovery only when the action code is `recover_custody`; otherwise proceed only when status confirms branch ownership is already returned and no recovery is required.
5. Treat custody recovery as ownership recovery, not content recovery.
6. Replace the obsolete work from the correct pre-invalidation base instead of building on the recovered-but-obsolete head, and keep the obsolete run's pipeline-fix commits out of the replacement.
7. Validate exactly once against the final replacement head so no obsolete or intermediate head becomes authoritative.

Apart from the supported abort above, do not hand-edit, commit, restart, or start a second validation run while the obsolete run owns the branch.
