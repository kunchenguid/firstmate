---
name: no-mistakes-validation
description: >-
  Agent-only procedure for driving a live no-mistakes validation run.
  Use before steering a supersession that invalidates work under validation, and before sending a worker the decision that answers an ask-user gate finding.
user-invocable: false
metadata:
  internal: true
---

# no-mistakes-validation

`AGENTS.md` section 13 indexes this skill's load trigger, and its section 7 "Validate" subsection owns the always-loaded boundaries: the rule that the task worker owns every `no-mistakes axi run` and `no-mistakes axi respond` call for its own run, the rule that firstmate never invokes `no-mistakes axi respond` for a crew-owned run, the scope boundary on new requirements, the ask-user escalation authority, and the rule that validation is judged by reconciled state rather than shell liveness or the run step.
This skill owns the two procedures that fire only inside a live run.
`bin/fm-crew-state.sh`'s header owns the exact state mapping, and current `no-mistakes axi --help` owns exact command syntax.

## Superseding work that is under validation

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
Corrections required to satisfy already accepted intent are not invalidation, and neither is a new requirement that merely adds to the accepted contract.

When that instruction does arrive, steer the worker through this exact sequence:

1. Cancel the active run through no-mistakes axi's supported abort command, and confirm through axi status that the run has stopped before changing any code.
2. Follow `branch_sync.next_action` from structured axi status.
   Use axi sync's supported guarded recovery only when its code is `recover_custody`.
   Otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
3. Replace the obsolete work from the correct pre-invalidation base.
   Custody recovery settles branch ownership, not content, so building on top of the recovered-but-obsolete head would carry the obsolete run's own pipeline-fix commits into what gets validated and shipped.
4. Validate exactly once against that final head, so no obsolete or intermediate head is ever treated as authoritative.

Apart from that single supported abort, the worker must not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
A worker doing any of those during an active run has duplicated pipeline ownership outside this sequence; steer it back to the gate response flow rather than letting the second owner proceed.

## Answering an ask-user gate finding

Decide the finding only when the configured authority permits, under `ask-user-authority`; otherwise escalate to the captain.
The implementation worker never answers its own finding.

Send the same worker one exact decision that names the decision key, the step, the action, the affected finding IDs, instructions where the action needs them, and the exact response command.
Require the matching `resolved` event before treating the gate as cleared.
Forbid `--yes`, which would answer gates the captain or firstmate has not actually decided.
Require the worker to process every synchronous return until the run reaches completion or a genuinely new escalation, rather than stopping at the first return.

Resume fleet supervision immediately after the decision lands; the run continues without further firstmate action until its next gate or outcome.
